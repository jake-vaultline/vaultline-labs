# Ingest configuration fulfillment

This is the governed handoff between an accepted landing-page application and a private team delivery. It never turns free-form applicant prose directly into filesystem rules. An authorized agent reviews the sanitized application, records unresolved questions in `openQuestions`, and fills `resolved` only from confirmed answers.

```bash
python3 fulfillment/ingest_fulfillment.py fulfill fulfillment/example-request.json /tmp/ingest-delivery
python3 fulfillment/ingest_fulfillment.py verify /tmp/ingest-delivery
```

The state model is `accepted → clarification → configured → synthetic-qa → release-bound → delivered`, with `failed` from any stage. Re-running the same resolved request produces the same profile and QA result; timestamps live only in the delivery receipt. Delivery is not marked here: the authorized delivery channel records recipient, time, exact manifest digest, and success separately without putting applicant data in Console.

The package uses the exact signed, notarized, stapled universal 0.3.0 release qualified under VLP-522. It does not build, sign, notarize, upload, or handle credentials. Each teammate installs the same app and imports the same portable profile; the offline app requires no account. A future hosted invitation/IAM system is separate scope.

Before real delivery, the agent must also import/export the profile in Ingest, compare the round trip, exercise a disposable synthetic source/destination, and inspect the preview, manifest, retry, collision, and source-unchanged behavior described in `CONFIGURATION.md`.
