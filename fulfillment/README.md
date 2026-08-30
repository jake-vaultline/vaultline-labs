# Ingest configuration fulfillment

This is the deterministic handoff between a visitor-confirmed scan recipe and a private team delivery. It never turns free-form prose or raw scan paths directly into filesystem rules. The scan-first UI must resolve every required choice into the bounded `resolved` object before requesting delivery; ambiguity stops before email instead of creating per-lead Factory work.

```bash
python3 fulfillment/ingest_fulfillment.py fulfill fulfillment/example-request.json /tmp/ingest-delivery
python3 fulfillment/ingest_fulfillment.py verify /tmp/ingest-delivery
```

The state model is `accepted → configured → synthetic-qa → release-bound → delivered`, with `clarification` retained only for the separate manual Factory path and `failed` from any stage. Re-running the same resolved request produces the same profile, RFC 4122 field IDs, and QA result; timestamps live only in the delivery receipt. The delivery channel records recipient, time, exact manifest digest, and provider acceptance separately without putting applicant data in Console.

The package uses the exact signed, notarized, stapled universal 0.3.0 release qualified under VLP-522. It does not build, sign, notarize, upload, or handle credentials. Each teammate installs the same app and imports the same portable profile; the offline app requires no account. A future hosted invitation/IAM system is separate scope.

The Swift test suite invokes this generator and imports its exact output through the released profile decoder. That golden contract replaces per-lead import/export work. Release qualification still exercises disposable media, preview, manifest, retry, collision, and source-unchanged behavior once per app release as described in `CONFIGURATION.md`.
