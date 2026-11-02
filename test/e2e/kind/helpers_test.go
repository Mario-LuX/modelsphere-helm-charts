//go:build e2e

package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// verboseOn is E2E_VERBOSE: print helm output, pod lists, the hostPath tree,
// the engine environment and cache-mgr log lines as specs pass.
// Off unless set to 1 or true. Failures dump the cluster either way.
func verboseOn() bool {
	v := os.Getenv("E2E_VERBOSE")
	return v == "1" || strings.EqualFold(v, "true")
}

func show(title, out string) {
	if !verboseOn() {
		return
	}
	_, _ = fmt.Fprintf(GinkgoWriter, "\n--- %s\n%s\n", title, strings.TrimRight(out, "\n"))
}

var acquiredRe = regexp.MustCompile(`\[cache-mgr\] Acquired (slot-\d+) \(fd \d+\) for template ([0-9a-f]+) \(lease fd \d+\)`)

type k8sPod struct {
	Metadata struct {
		Name              string  `json:"name"`
		DeletionTimestamp *string `json:"deletionTimestamp"`
	} `json:"metadata"`
	Spec struct {
		Containers []k8sContainer `json:"containers"`
	} `json:"spec"`
	Status struct {
		Phase             string         `json:"phase"`
		ContainerStatuses []k8sContainerStatus `json:"containerStatuses"`
	} `json:"status"`
}

type k8sContainer struct {
	Name    string   `json:"name"`
	Command []string `json:"command"`
	Args    []string `json:"args"`
	Env     []struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	} `json:"env"`
}

type k8sContainerStatus struct {
	Name         string `json:"name"`
	Ready        bool   `json:"ready"`
	RestartCount int    `json:"restartCount"`
	State        struct {
		Waiting *struct {
			Reason string `json:"reason"`
		} `json:"waiting"`
		Terminated *struct {
			ExitCode int    `json:"exitCode"`
			Reason   string `json:"reason"`
		} `json:"terminated"`
	} `json:"state"`
	LastState struct {
		Terminated *struct {
			ExitCode int    `json:"exitCode"`
			Reason   string `json:"reason"`
		} `json:"terminated"`
	} `json:"lastState"`
}

func (p k8sPod) container(name string) (k8sContainer, bool) {
	for _, c := range p.Spec.Containers {
		if c.Name == name {
			return c, true
		}
	}
	return k8sContainer{}, false
}

func (p k8sPod) status(name string) (k8sContainerStatus, bool) {
	for _, st := range p.Status.ContainerStatuses {
		if st.Name == name {
			return st, true
		}
	}
	return k8sContainerStatus{}, false
}

func (p k8sPod) engineReady(container string) bool {
	if p.Metadata.DeletionTimestamp != nil || p.Status.Phase != "Running" {
		return false
	}
	st, ok := p.status(container)
	return ok && st.Ready
}

func (st k8sContainerStatus) exitCode() (int, bool) {
	if st.State.Terminated != nil {
		return st.State.Terminated.ExitCode, true
	}
	if st.LastState.Terminated != nil {
		return st.LastState.Terminated.ExitCode, true
	}
	return 0, false
}

func (p k8sPod) specEnv(container, name string) string {
	c, ok := p.container(container)
	if !ok {
		return ""
	}
	for _, e := range c.Env {
		if e.Name == name {
			return e.Value
		}
	}
	return ""
}

type podLease struct {
	pod      k8sPod
	slot     string
	hash     string
	logs     string
	procEnv  map[string]string
	symlink  string
}

func fetchPods(ch chart) ([]k8sPod, error) {
	out, err := kubectl("-n", namespace, "get", "pods", "-l", "app="+ch.appLabel(), "-o", "json")
	if err != nil {
		return nil, err
	}
	var list struct {
		Items []k8sPod `json:"items"`
	}
	if err := json.Unmarshal([]byte(out), &list); err != nil {
		return nil, fmt.Errorf("parse pods: %w\n%s", err, out)
	}
	return list.Items, nil
}

func readyPods(g Gomega, ch chart) []k8sPod {
	pods, err := fetchPods(ch)
	g.Expect(err).NotTo(HaveOccurred())
	var ready []k8sPod
	for _, p := range pods {
		if p.engineReady(ch.Container) {
			ready = append(ready, p)
		}
	}
	return ready
}

func containerLogs(pod, container string) string {
	out, err := kubectlQuiet("-n", namespace, "logs", pod, "-c", container, "--tail=400")
	prev, errPrev := kubectlQuiet("-n", namespace, "logs", pod, "-c", container, "--previous", "--tail=400")
	switch {
	case err == nil && errPrev == nil:
		return prev + "\n" + out
	case err == nil:
		return out
	case errPrev == nil:
		return prev
	default:
		return out + "\n" + prev
	}
}

func cacheMgrLines(logs string) string {
	var b strings.Builder
	for _, line := range strings.Split(logs, "\n") {
		if strings.Contains(line, "[cache-mgr]") || strings.Contains(line, "[mock]") {
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func parseAcquired(logs string) (slot, hash string) {
	matches := acquiredRe.FindAllStringSubmatch(logs, -1)
	Expect(matches).NotTo(BeEmpty(), "cache-mgr did not log an acquired slot:\n%s", logs)
	last := matches[len(matches)-1]
	return last[1], last[2]
}

func processEnvAndLink(pod, container, linkPath string) (map[string]string, string) {
	script := `
import os, sys
data = open("/proc/1/environ", "rb").read().split(b"\0")
for item in data:
    if item:
        print(item.decode())
print("__SYMLINK__")
print(os.readlink(sys.argv[1]))
`
	out, err := kubectl("-n", namespace, "exec", pod, "-c", container, "--", "python3", "-c", script, linkPath)
	Expect(err).NotTo(HaveOccurred(), out)
	parts := strings.SplitN(out, "\n__SYMLINK__\n", 2)
	Expect(parts).To(HaveLen(2), out)
	env := map[string]string{}
	for _, line := range strings.Split(parts[0], "\n") {
		if line == "" {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		Expect(ok).To(BeTrue(), line)
		env[k] = v
	}
	return env, strings.TrimSpace(parts[1])
}

func readLease(p k8sPod, ch chart) podLease {
	logs := containerLogs(p.Metadata.Name, ch.Container)
	slot, hash := parseAcquired(logs)
	env, link := processEnvAndLink(p.Metadata.Name, ch.Container, ch.Symlink)
	if verboseOn() {
		show(p.Metadata.Name+" cache-mgr", cacheMgrLines(logs))
		show(p.Metadata.Name+" env", formatEnv(env, ch))
		show(p.Metadata.Name+" symlink", link)
	}
	return podLease{pod: p, slot: slot, hash: hash, logs: logs, procEnv: env, symlink: link}
}

func formatEnv(env map[string]string, ch chart) string {
	var keys []string
	keys = append(keys, ch.Popped...)
	keys = append(keys, ch.Kept...)
	for _, b := range ch.Binds {
		keys = append(keys, b.Name)
	}
	var b strings.Builder
	seen := map[string]bool{}
	for _, k := range keys {
		if seen[k] {
			continue
		}
		seen[k] = true
		if v, ok := env[k]; ok {
			fmt.Fprintf(&b, "%s=%s\n", k, v)
		} else {
			fmt.Fprintf(&b, "%s=<absent>\n", k)
		}
	}
	return b.String()
}

func markerCount(ch chart, hash, slot string) int {
	path := ch.markerPath(hash, slot)
	out, err := nodeQuiet("cat", path)
	Expect(err).NotTo(HaveOccurred(), "cat %s: %s", path, out)
	line := strings.TrimSpace(strings.Split(out, "\n")[0])
	n, err := strconv.Atoi(line)
	Expect(err).NotTo(HaveOccurred(), "marker %s: %q", path, out)
	return n
}

func hostTree(ch chart) string {
	out, err := nodeQuiet("sh", "-c", "find "+ch.HostPath+" -maxdepth 6 -print | sort")
	if err != nil {
		return out + "\n" + err.Error()
	}
	return out
}

func observe(ch chart) {
	if !verboseOn() {
		return
	}
	out, err := kubectl("-n", namespace, "get", "pods", "-o", "wide")
	if err != nil {
		out += "\n" + err.Error()
	}
	show("pods", out)
	show("hostPath "+ch.HostPath, hostTree(ch))
}

func dumpChart(ch chart, why string) {
	_, _ = fmt.Fprintf(GinkgoWriter, "\n==> dumping %s (%s)\n", ch.Name, why)
	dump := func(title string, args ...string) {
		out, err := kubectl(args...)
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- %s\n%s\n", title, tail(out, 200))
		if err != nil {
			_, _ = fmt.Fprintf(GinkgoWriter, "error: %v\n", err)
		}
	}
	dump("pods", "-n", namespace, "get", "pods", "-o", "wide")
	dump("describe", "-n", namespace, "describe", "pods")
	pods, err := fetchPods(ch)
	if err != nil {
		_, _ = fmt.Fprintf(GinkgoWriter, "list pods: %v\n", err)
	}
	for _, p := range pods {
		dump(p.Metadata.Name+" logs", "-n", namespace, "logs", p.Metadata.Name, "--all-containers", "--tail=200")
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- %s previous\n%s\n", p.Metadata.Name, containerLogs(p.Metadata.Name, ch.Container))
	}
	_, _ = fmt.Fprintf(GinkgoWriter, "\n--- hostPath %s\n%s\n", ch.HostPath, hostTree(ch))
}
