//go:build e2e

package e2e

import (
	"fmt"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("host compile cache", func() {
	for _, ch := range chartsUnderTest() {
		ch := ch
		Describe(ch.Name, Ordered, func() {
			var hashA, hashB, hashC string

			BeforeAll(func() {
				By("installing " + ch.Name + " with the host cache enabled")
				uninstallRelease()
				wipeCache(ch)
				helmUpgrade(ch, true, nil)
			})

			AfterAll(func() {
				uninstallRelease()
				if beforeSuiteOK {
					wipeCache(ch)
				}
			})

			AfterEach(func() {
				if CurrentSpecReport().Failed() {
					dumpChart(ch, CurrentSpecReport().FullText())
				}
			})

			It("leases a distinct slot for each ready pod", func() {
				var ready []k8sPod
				Eventually(func(g Gomega) {
					ready = readyPods(g, ch)
					g.Expect(ready).To(HaveLen(2))
				}).Should(Succeed())

				leases := make([]podLease, 0, len(ready))
				slots := map[string]string{}
				for _, p := range ready {
					l := readLease(p, ch)
					leases = append(leases, l)
					slots[l.slot] = p.Metadata.Name
				}
				Expect(slots).To(HaveLen(2), "replicas must not share a slot: %+v", slots)
				Expect(leases[0].hash).To(Equal(leases[1].hash))
				hashA = leases[0].hash

				for _, l := range leases {
					assertLease(ch, l, "2")
				}
				Expect(nodeExists(ch.templateDir(hashA) + "/.last_used")).To(BeTrue())
				Expect(nodeExists(ch.lockDir(hashA) + "/.lease")).To(BeTrue())
				observe(ch)
			})

			It("exits when maxSlotsPerNode is exhausted, then recovers", func() {
				// acquire_slot uses LOCK_EX|LOCK_NB and, with every slot held,
				// writes the error below and exits 1. It does not wait and it
				// does not fall back to an unleased directory.
				var before []podLease
				Eventually(func(g Gomega) {
					ready := readyPods(g, ch)
					g.Expect(ready).To(HaveLen(2))
				}).Should(Succeed())
				for _, p := range readyPods(Default, ch) {
					before = append(before, readLease(p, ch))
				}

				DeferCleanup(func() {
					helmUpgrade(ch, true, map[string]string{"replicaCount": "2"})
				})
				By("scaling to 3 replicas with 2 slots")
				helmUpgrade(ch, false, map[string]string{"replicaCount": "3"})

				Eventually(func(g Gomega) {
					pods, err := fetchPods(ch)
					g.Expect(err).NotTo(HaveOccurred())
					var live, ready, failed []k8sPod
					for _, p := range pods {
						if p.Metadata.DeletionTimestamp != nil {
							continue
						}
						live = append(live, p)
						if p.engineReady(ch.Container) {
							ready = append(ready, p)
						} else {
							failed = append(failed, p)
						}
					}
					g.Expect(live).To(HaveLen(3), "want 3 pods, have %d", len(live))
					g.Expect(ready).To(HaveLen(2))
					g.Expect(failed).To(HaveLen(1))
					st, ok := failed[0].status(ch.Container)
					g.Expect(ok).To(BeTrue(), "engine container has no status yet")
					code, hasCode := st.exitCode()
					g.Expect(hasCode).To(BeTrue(), "engine has not exited yet: %+v", st)
					g.Expect(code).To(Equal(1))
					logs := containerLogs(failed[0].Metadata.Name, ch.Container)
					want := fmt.Sprintf(
						"[cache-mgr] ERROR: All 2 cache slots are in use on this node (locks: %s/.locks/%s)!",
						ch.HostMount, hashA,
					)
					g.Expect(logs).To(ContainSubstring(want), logs)
					if verboseOn() {
						show(failed[0].Metadata.Name+" cache-mgr", cacheMgrLines(logs))
					}
				}).Should(Succeed())

				Expect(nodeExists(ch.templateDir(hashA) + "/slot-2")).To(BeFalse())
				Expect(nodeExists(ch.lockDir(hashA) + "/slot-2.lock")).To(BeFalse())
				for _, l := range before {
					Expect(nodeExists(ch.lockDir(hashA) + "/" + l.slot + ".lock")).To(BeTrue())
				}
				observe(ch)
			})

			It("switches to a new template directory and keeps the previous one", func() {
				By("upgrading the image tag, which changes the template hash")
				helmUpgrade(ch, true, map[string]string{"image.tag": tagB})

				var ready []k8sPod
				Eventually(func(g Gomega) {
					ready = readyPods(g, ch)
					g.Expect(ready).To(HaveLen(2))
				}).Should(Succeed())

				leases := make([]podLease, 0, 2)
				for _, p := range ready {
					leases = append(leases, readLease(p, ch))
				}
				Expect(leases[0].hash).To(Equal(leases[1].hash))
				hashB = leases[0].hash
				Expect(hashB).NotTo(Equal(hashA))
				for _, l := range leases {
					assertLease(ch, l, "2")
					Expect(l.logs).NotTo(ContainSubstring("Purging abandoned"))
				}
				Expect(nodeExists(ch.templateDir(hashA))).To(BeTrue(), "historyLimit 2 keeps the previous template")
				Expect(nodeExists(ch.lockDir(hashA))).To(BeTrue())
				Expect(nodeExists(ch.templateDir(hashB))).To(BeTrue())
				observe(ch)
			})

			It("purges an abandoned template and skips one that is still leased", func() {
				// historyLimit 1 makes every template other than the new one a
				// GC candidate. maxUnavailable 0 means the new pod runs that GC
				// while a pod on the previous template still holds the shared
				// lease, so that template is skipped and the older one is purged.
				By("upgrading to a third image tag with historyLimit 1")
				helmUpgrade(ch, true, map[string]string{
					"image.tag":          tagC,
					"cache.historyLimit": "1",
				})

				var ready []k8sPod
				Eventually(func(g Gomega) {
					ready = readyPods(g, ch)
					g.Expect(ready).To(HaveLen(2))
				}).Should(Succeed())

				var combined strings.Builder
				leases := make([]podLease, 0, 2)
				for _, p := range ready {
					l := readLease(p, ch)
					leases = append(leases, l)
					combined.WriteString(l.logs)
					combined.WriteByte('\n')
				}
				Expect(leases[0].hash).To(Equal(leases[1].hash))
				hashC = leases[0].hash
				Expect(hashC).NotTo(Equal(hashB))
				Expect(hashC).NotTo(Equal(hashA))
				for _, l := range leases {
					assertLease(ch, l, "1")
				}

				Expect(combined.String()).To(ContainSubstring(
					"[cache-mgr] GC: Purging abandoned template cache " + hashA))
				Expect(combined.String()).To(ContainSubstring(
					"[cache-mgr] GC: Cache " + hashB + " is leased, skipping"))

				Expect(nodeExists(ch.templateDir(hashA))).To(BeFalse(), "abandoned template %s should be purged", hashA)
				Expect(nodeExists(ch.lockDir(hashA))).To(BeFalse(), "locks for %s go with the template", hashA)
				Expect(nodeExists(ch.templateDir(hashB))).To(BeTrue(), "leased template %s is kept", hashB)
				Expect(nodeExists(ch.lockDir(hashB)+"/.lease")).To(BeTrue())
				Expect(nodeExists(ch.templateDir(hashC))).To(BeTrue())
				observe(ch)
			})

			It("re-leases a released slot and reuses its marker", func() {
				var ready []k8sPod
				Eventually(func(g Gomega) {
					ready = readyPods(g, ch)
					g.Expect(ready).To(HaveLen(2))
				}).Should(Succeed())
				victim := readLease(ready[0], ch)
				survivor := readLease(ready[1], ch)
				Expect(victim.hash).To(Equal(hashC))
				Expect(survivor.hash).To(Equal(hashC))
				Expect(victim.slot).NotTo(Equal(survivor.slot))
				victimCount := markerCount(ch, hashC, victim.slot)
				survivorCount := markerCount(ch, hashC, survivor.slot)
				Expect(victimCount).To(BeNumerically(">=", 1))

				By("deleting " + victim.pod.Metadata.Name + " (" + victim.slot + ")")
				mustKubectl("-n", namespace, "delete", "pod", victim.pod.Metadata.Name, "--wait=true", "--timeout=90s")

				Eventually(func(g Gomega) {
					pods := readyPods(g, ch)
					g.Expect(pods).To(HaveLen(2))
					names := map[string]bool{}
					for _, p := range pods {
						names[p.Metadata.Name] = true
					}
					g.Expect(names).To(HaveKey(survivor.pod.Metadata.Name))
					g.Expect(names).NotTo(HaveKey(victim.pod.Metadata.Name))
				}).Should(Succeed())

				var replaced podLease
				var survivorNow podLease
				for _, p := range readyPods(Default, ch) {
					l := readLease(p, ch)
					if p.Metadata.Name == survivor.pod.Metadata.Name {
						survivorNow = l
					} else {
						replaced = l
					}
				}
				Expect(replaced.pod.Metadata.Name).NotTo(BeEmpty())
				Expect(replaced.hash).To(Equal(hashC))
				Expect(replaced.slot).To(Equal(victim.slot), "the free slot is the one the deleted pod released")
				Expect(markerCount(ch, hashC, replaced.slot)).To(Equal(victimCount+1),
					"the replacement reads the previous run's compiled.marker and counts one more start")
				Expect(survivorNow.slot).To(Equal(survivor.slot))
				Expect(survivorNow.hash).To(Equal(hashC))
				Expect(markerCount(ch, hashC, survivor.slot)).To(Equal(survivorCount))
				observe(ch)
			})
		})
	}
})

// assertLease checks one ready pod against the cache manager's contract:
// distinct slot directory, lock files, engine environment, symlink, and the
// template hash published on the pod matching the directory name.
func assertLease(ch chart, l podLease, history string) {
	p := l.pod
	c, ok := p.container(ch.Container)
	Expect(ok).To(BeTrue())
	Expect(c.Command).To(Equal(ch.command()))
	Expect(c.Args).To(ContainElement(HavePrefix("--port=")))

	Expect(p.specEnv(ch.Container, ch.HashEnv)).To(Equal(l.hash),
		"template directory %s does not match the pod env %s", l.hash, ch.HashEnv)
	Expect(p.specEnv(ch.Container, ch.envName("MAX_SLOTS"))).To(Equal("2"))
	Expect(p.specEnv(ch.Container, ch.envName("HISTORY_LIMIT"))).To(Equal(history))
	Expect(l.logs).To(ContainSubstring(
		fmt.Sprintf("[cache-mgr] Acquired %s (fd ", l.slot)))
	Expect(l.logs).To(ContainSubstring("for template " + l.hash))

	slot := ch.slotPath(l.hash, l.slot)
	for _, b := range ch.Binds {
		want := slot
		if b.Rel != "" {
			want = slot + "/" + b.Rel
		}
		Expect(l.procEnv).To(HaveKeyWithValue(b.Name, want))
	}
	Expect(l.symlink).To(Equal(l.procEnv[ch.LinkEnv]), "symlink %s", ch.Symlink)

	for _, name := range ch.Popped {
		Expect(l.procEnv).NotTo(HaveKey(name), "control var %s must not reach the engine", name)
	}
	for _, name := range ch.Kept {
		Expect(l.procEnv).To(HaveKey(name))
	}
	if len(ch.Popped) == 0 {
		Expect(l.procEnv[ch.HashEnv]).To(Equal(l.hash))
		Expect(l.procEnv[ch.envName("HOST_DIR")]).To(Equal(ch.HostMount))
	}

	Expect(nodeExists(ch.templateDir(l.hash) + "/" + l.slot)).To(BeTrue())
	Expect(nodeExists(ch.lockDir(l.hash) + "/" + l.slot + ".lock")).To(BeTrue())
	Expect(nodeExists(ch.markerPath(l.hash, l.slot))).To(BeTrue())
	Expect(markerCount(ch, l.hash, l.slot)).To(BeNumerically(">=", 1))
}
