import collections, csv, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
C = collections.Counter
print("domains:", len(rows))
print("baseline stages:", C(r["b_stage"] for r in rows).most_common())
live = [r for r in rows if r["b_stage"] == "done"]
print("live (baseline got a response):", len(live))
print("  baseline TLS:", C(r["b_ver"] for r in live).most_common())
print("mbedTLS stages on live:", C(r["m_stage"] for r in live).most_common())
ok = [r for r in live if r["m_stage"] == "done"]
bad = [r for r in live if r["m_stage"] != "done"]
print("mbedTLS OK on live: %d / %d = %.1f%%" % (len(ok), len(live), 100 * len(ok) / len(live)))
print("  suites:", C(r["m_suite"] for r in ok).most_common())
print("  cert keys:", C(r["m_pk"] + str(r["m_bits"]) for r in ok).most_common())
print("failures by error:")
for (st, err), n in C((r["m_stage"], r["m_err"]) for r in bad).most_common():
    print("  %3d %s %s" % (n, st, err))
print("failure detail (baseline ver/cipher):")
for r in bad:
    print("  %-40s %-9s %-10s %-32s %s" % (r["host"][:40], r["m_stage"], r["b_ver"], r["b_cipher"][:32], r["m_err"][:60]))
other = [r for r in rows if r["b_stage"] != "done" and r["m_stage"] == "done"]
print("mbedTLS OK where baseline failed:", len(other), [r["host"] for r in other][:10])
