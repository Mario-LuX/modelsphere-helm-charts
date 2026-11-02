//go:build e2e

package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	releaseName   = "cache"
	namespace     = "cache-e2e"
	imageRepo     = "e2e-cache-engine"
	tagA          = "a"
	tagB          = "b"
	tagC          = "c"
	modelHostPath = "/var/lib/e2e/model"
	helmWait      = "4m"
	readyWait     = 90 * time.Second
)

type suiteConfig struct {
	kindBin    string
	kubectlBin string
	helmBin    string
	cluster    string
	context    string
}

type envBind struct {
	Name string
	// Rel is the path under the leased slot. Empty means the slot directory.
	Rel string
}

// chart is one engine chart the suite installs. Paths match the cache manager:
// the pod mounts <HostPath>/<Suffix> at HostMount, and the manager leases
// <HostMount>/<templateHash>/slot-N.
type chart struct {
	Name      string
	Container string
	HashEnv   string
	HostMount string
	HostPath  string
	Suffix    string
	Symlink   string
	LinkEnv   string
	MarkerRel string
	Binds     []envBind
	// Popped are control variables cache_manager.py removes before exec.
	Popped []string
	// Kept are control variables the engine process still has (sglang does not pop them).
	Kept []string
}

func (c chart) appLabel() string { return releaseName + "-" + c.Name }

func (c chart) nodeRoot() string { return c.HostPath + "/" + c.Suffix }

func (c chart) templateDir(hash string) string { return c.nodeRoot() + "/" + hash }

func (c chart) lockDir(hash string) string { return c.nodeRoot() + "/.locks/" + hash }

func (c chart) markerPath(hash, slot string) string {
	return c.templateDir(hash) + "/" + slot + "/" + c.MarkerRel
}

func (c chart) slotPath(hash, slot string) string {
	return c.HostMount + "/" + hash + "/" + slot
}

func (c chart) envName(suffix string) string {
	return strings.TrimSuffix(c.HashEnv, "TEMPLATE_HASH") + suffix
}

func (c chart) command() []string {
	return []string{"python3", "/opt/" + c.Name + "-cache/cache_manager.py", "--", c.Name, "serve"}
}

var (
	cfg  suiteConfig
	root string

	beforeSuiteOK bool
	kubeconfigDir string

	vllmChart = chart{
		Name:      "vllm",
		Container: "vllm",
		HashEnv:   "VLLM_CACHE_TEMPLATE_HASH",
		HostMount: "/var/cache/vllm-host",
		HostPath:  "/var/lib/e2e/vllm-cache",
		Suffix:    "e2e",
		Symlink:   "/root/.cache/vllm",
		LinkEnv:   "VLLM_CACHE_ROOT",
		MarkerRel: "vllm/compiled.marker",
		Binds: []envBind{
			{"VLLM_CACHE_ROOT", "vllm"},
			{"TRITON_CACHE_DIR", "triton"},
			{"TORCHINDUCTOR_CACHE_DIR", "inductor"},
			{"CUDA_CACHE_PATH", "nv-compute"},
			{"DG_JIT_CACHE_DIR", "deep_gemm"},
			{"FLASHINFER_WORKSPACE_BASE", "flashinfer"},
			{"HF_HOME", "huggingface"},
		},
		Popped: []string{
			"VLLM_CACHE_HOST_DIR",
			"VLLM_CACHE_TEMPLATE_HASH",
			"VLLM_CACHE_MAX_SLOTS",
			"VLLM_CACHE_HISTORY_LIMIT",
		},
	}

	sglangChart = chart{
		Name:      "sglang",
		Container: "sglang",
		HashEnv:   "SGLANG_CACHE_TEMPLATE_HASH",
		HostMount: "/var/cache/sglang-host",
		HostPath:  "/var/lib/e2e/sglang-cache",
		Suffix:    "e2e",
		Symlink:   "/root/.cache/sglang",
		LinkEnv:   "SGLANG_CACHE_DIR",
		MarkerRel: "compiled.marker",
		Binds: []envBind{
			{"SGLANG_CACHE_DIR", ""},
			{"HF_HOME", "huggingface"},
		},
		Kept: []string{
			"SGLANG_CACHE_HOST_DIR",
			"SGLANG_CACHE_TEMPLATE_HASH",
			"SGLANG_CACHE_MAX_SLOTS",
			"SGLANG_CACHE_HISTORY_LIMIT",
		},
	}
)

func TestE2E(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "host cache e2e")
}

func chartsUnderTest() []chart {
	switch os.Getenv("E2E_CHART") {
	case "", "both":
		return []chart{vllmChart, sglangChart}
	case "vllm":
		return []chart{vllmChart}
	case "sglang":
		return []chart{sglangChart}
	default:
		panic(fmt.Sprintf("E2E_CHART must be sglang, vllm, or empty (both), not %q", os.Getenv("E2E_CHART")))
	}
}

var _ = BeforeSuite(func() {
	SetDefaultEventuallyTimeout(readyWait)
	SetDefaultEventuallyPollingInterval(time.Second)

	cfg = loadConfig()
	for _, bin := range []string{cfg.kindBin, cfg.kubectlBin, cfg.helmBin, "docker"} {
		_, err := exec.LookPath(bin)
		Expect(err).NotTo(HaveOccurred(), "%s is not installed", bin)
	}
	var err error
	root, err = filepath.Abs("../../..")
	Expect(err).NotTo(HaveOccurred())

	By("using kube context " + cfg.context)
	kubeconfigDir, err = os.MkdirTemp("", "cache-e2e-")
	Expect(err).NotTo(HaveOccurred())
	kc, err := run(exec.Command(cfg.kindBin, "get", "kubeconfig", "--name", cfg.cluster))
	Expect(err).NotTo(HaveOccurred(), kc)
	kubeconfig := filepath.Join(kubeconfigDir, "kubeconfig")
	Expect(os.WriteFile(kubeconfig, []byte(kc), 0o600)).To(Succeed())
	Expect(os.Setenv("KUBECONFIG", kubeconfig)).To(Succeed())
	mustKubectl("get", "nodes")

	buildAndLoadImages()
	prepareModelDir()
	for _, ch := range chartsUnderTest() {
		helmDep(ch)
	}
	beforeSuiteOK = true
})

var _ = AfterSuite(func() {
	if !beforeSuiteOK && cfg.context != "" {
		out, err := kubectl("get", "pods", "-A", "-o", "wide")
		_, _ = fmt.Fprintf(GinkgoWriter, "\n--- pods\n%s\n", out)
		if err != nil {
			_, _ = fmt.Fprintf(GinkgoWriter, "error: %v\n", err)
		}
	}
	if kubeconfigDir != "" {
		_ = os.RemoveAll(kubeconfigDir)
	}
})

func loadConfig() suiteConfig {
	c := suiteConfig{
		kindBin:    envOr("KIND", "kind"),
		kubectlBin: envOr("KUBECTL", "kubectl"),
		helmBin:    envOr("HELM", "helm"),
		cluster:    envOr("KIND_CLUSTER", "cache-e2e"),
	}
	c.context = "kind-" + c.cluster
	return c
}

func buildAndLoadImages() {
	By("building the mock engine image")
	ctx := filepath.Join(root, "test", "e2e", "kind", "mock-engine")
	_, err := run(exec.Command("docker", "build", "-t", imageRepo+":"+tagA, ctx))
	Expect(err).NotTo(HaveOccurred())
	for _, tag := range []string{tagB, tagC} {
		_, err = run(exec.Command("docker", "tag", imageRepo+":"+tagA, imageRepo+":"+tag))
		Expect(err).NotTo(HaveOccurred())
	}
	By("loading the mock engine into kind")
	args := []string{"load", "docker-image", "--name", cfg.cluster}
	for _, tag := range []string{tagA, tagB, tagC} {
		args = append(args, imageRepo+":"+tag)
	}
	_, err = run(exec.Command(cfg.kindBin, args...))
	Expect(err).NotTo(HaveOccurred())
}

func prepareModelDir() {
	By("creating the model directory on the kind node")
	_, err := nodeRun("mkdir", "-p", modelHostPath)
	Expect(err).NotTo(HaveOccurred())
	_, err = nodeRun("sh", "-c", `printf '%s\n' '{"model_type":"e2e"}' > `+modelHostPath+`/config.json`)
	Expect(err).NotTo(HaveOccurred())
}

func helmDep(ch chart) {
	cmd := exec.Command(cfg.helmBin, "dependency", "build", "--skip-refresh", filepath.Join(root, "charts", ch.Name))
	_, err := run(cmd)
	Expect(err).NotTo(HaveOccurred())
}

func helmUpgrade(ch chart, wait bool, sets map[string]string) {
	args := []string{
		"upgrade", "--install", releaseName,
		"--namespace", namespace,
		"--create-namespace",
		filepath.Join(root, "charts", ch.Name),
		"--values", filepath.Join(root, "test", "e2e", "kind", "values-"+ch.Name+".yaml"),
	}
	keys := make([]string, 0, len(sets))
	for k := range sets {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		args = append(args, "--set", k+"="+sets[k])
	}
	if wait {
		args = append(args, "--wait", "--timeout", helmWait)
	}
	out, err := helm(args...)
	Expect(err).NotTo(HaveOccurred(), tail(out, 120))
	if verboseOn() {
		show("helm", out)
	}
}

func uninstallRelease() {
	out, err := helm("uninstall", releaseName, "--namespace", namespace, "--wait", "--timeout", "2m")
	if err != nil && !strings.Contains(out+err.Error(), "not found") {
		Expect(err).NotTo(HaveOccurred(), out)
	}
}

func wipeCache(ch chart) {
	_, err := nodeRun("rm", "-rf", ch.HostPath)
	Expect(err).NotTo(HaveOccurred())
}

func run(cmd *exec.Cmd) (string, error) {
	command := strings.Join(cmd.Args, " ")
	_, _ = fmt.Fprintf(GinkgoWriter, "running: %s\n", command)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%s failed: %w\n%s", command, err, out)
	}
	return string(out), nil
}

func runQuiet(cmd *exec.Cmd) (string, error) {
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%s failed: %w\n%s", strings.Join(cmd.Args, " "), err, out)
	}
	return string(out), nil
}

func kubectl(args ...string) (string, error) {
	return run(exec.Command(cfg.kubectlBin, append([]string{"--context", cfg.context}, args...)...))
}

func kubectlQuiet(args ...string) (string, error) {
	return runQuiet(exec.Command(cfg.kubectlBin, append([]string{"--context", cfg.context}, args...)...))
}

func mustKubectl(args ...string) string {
	out, err := kubectl(args...)
	Expect(err).NotTo(HaveOccurred(), out)
	return out
}

func helm(args ...string) (string, error) {
	return run(exec.Command(cfg.helmBin, append([]string{"--kube-context", cfg.context}, args...)...))
}

func node() string { return cfg.cluster + "-control-plane" }

func nodeRun(args ...string) (string, error) {
	return run(exec.Command("docker", append([]string{"exec", node()}, args...)...))
}

func nodeQuiet(args ...string) (string, error) {
	return runQuiet(exec.Command("docker", append([]string{"exec", node()}, args...)...))
}

func nodeExists(path string) bool {
	_, err := nodeQuiet("test", "-e", path)
	return err == nil
}

func envOr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

func nonEmptyLines(s string) []string {
	var res []string
	for _, line := range strings.Split(s, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			res = append(res, line)
		}
	}
	return res
}

func tail(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}
