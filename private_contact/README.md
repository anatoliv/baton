# Private contact candidate

This package implements optional installation-bound verified contact, reviewed
case notices and private access. It defaults off. The protected executable loader
requires exact source/runtime pins, private input locators, custody separation,
operational approval and qualified sending/backup facts before production admission.
The [disabled manifest](manifest.disabled.json) supplies no credentials or paths.
The [runtime runbook](../docs/song-sharing-private-contact-runtime-2026-10-07.md)
records contracts, exact command forms and the remaining operational gates.

The public share service authenticates its existing installation bearer and
issues a short-lived purpose-bound opaque grant. The private worker consumes that
grant over an authenticated loopback readback; the public process holds only the
reader verifier. Public share fragments never prove ownership. Private operator
requests additionally require signed path/body/expiry/nonce envelopes. Committed
server receipt inventory identifies required notices independently of enqueue.

ContactService distinguishes accepted SMTP submission, verified provider feedback
and originating-installation private notice access. The production-shaped SMTP
adapter uses the adopted SES endpoint with verified STARTTLS; SNS admission checks
the pinned certificate, exact topic/account/sender and signed event. No live
provider connection or feedback route has been qualified by the local tests.

AES-GCM SQLite custody stores sealed private state. JournaledCustody commits the
separately retained authoritative checkpoint before the primary cache. Restoring
an old primary remains blocked until authenticated reconciliation replaces it
with live authoritative history. The authority/replay ledger is retained separately.
Whole-database rollback is outside this restore protocol and needs host controls.
Exports remain sealed; remote synchronization, held-case retention and destructive
expiration require operational evidence. Destructive expiration is disabled.

The tests use stdlib unittest, public cryptographic vectors, disposable owned
directories, reserved `.invalid` recipients and captured transport. The qualified
interpreter and narrow exact commands are in the
[test extension](../.claude/skill-extensions/test-writer-agent/EXTENSION.md).
The connected test starts the actual local Swift share executable and private Unix
handler, observes authorized notice access and withdrawal, then stops its process
and server thread. It proves the local source boundary, not a native screen,
production deployment, actual inbox delivery or staffed escalation.

## Standalone SNS feedback admission

`SNSFeedback.admit(raw_bytes)` checks the original Notification signature using
`cryptography` RSA PKCS#1 v1.5 with AWS SignatureVersion 1/SHA1 or 2/SHA256.
Constructor arguments must supply the exact approved SNS topic ARN, SES sending
account, envelope MAIL FROM (`mail.source`) and configuration set. It reads no
private configuration, environment, credentials or recipient identity. Supported
commercial AWS SNS regions use the exact configured region's public HTTPS host;
other AWS partitions and subscription confirmation are refused.

The default public certificate transport allows only that SNS host and its
`SimpleNotificationService-*.pem` path. It refuses redirects, userinfo, explicit
ports, query strings, fragments and alternate hosts. TLS validates the server;
the returned RSA certificate must be currently valid. A short-lived isolated
worker, with no inherited environment, bounds the whole fetch to three seconds,
including DNS. It limits certificate bytes to 16 KiB. No real fetch was executed
for local acceptance. Production process permissions and outbound connectivity
are still unqualified.

Both JSON layers reject duplicate keys, nonfinite numbers and nesting beyond 32;
the original body is limited to 256 KiB. SES JSON is parsed only after signature
verification. The only returned fields are `event` (the stable `sns:`-prefixed SNS
message UUID), `message` (SES-assigned `mail.messageId`) and `outcome`. Delivery,
DeliveryDelay, Bounce, Complaint and Reject map to the orchestration's existing
bounded outcomes. Recipients, headers, diagnostics and case text never leave
admission. `SNSFeedbackDenied` exposes only a fixed category; transport failure
is `unavailable`, which a future receiver must preserve as retryable instead of
acknowledging loss. The adapter writes no logs or state and sets no replay TTL,
suppression policy or retention policy. Correlation and deduplication remain in
the private orchestration.

Run the reserved offline qualification with a Python runtime containing
`cryptography` (the acceptance runtime had version 50.0.2):

```sh
python3 -m unittest private_contact.tests.test_sns_feedback -v
```

Fixtures sign reserved `.invalid` data with ephemeral test keys, independently
construct the AWS canonical string and inject captured public certificates.
The real transport's host, redirect, byte and deadline behavior is checked with
mocked network/process boundaries. A test-only subclass marks the validator
synthetic to exercise known-send correlation, duplicate delivery, foreign and
orphan refusal, and late delivery after bounce/withdrawal. This subclass does not
exist in the adapter. Ordinary `ContactService` construction remains disabled.
Passing fixtures do not establish a deployed receiver, private forwarding,
provider feedback, actual mail-server delivery or a production contact service.
Those operational acceptance gates remain open.
The approved topic's publisher permissions must also be qualified: an SNS
signature authenticates SNS publication, and does not independently prove that
SES was the publisher. Exact payload scope and known-send correlation do not
replace that operational restriction.

## Local protected-worker feedback integration

`feedback.py` is the protected-worker compatibility adapter. It retains the
qualified worker's pinned certificate URL/fingerprint, SES identity ARN,
900-second freshness, 64-KiB body ceiling, raw SNS UUID deduplication namespace
and Rendering Failure rejection. It adds exact configuration-set admission using
the strict validator. Its production-ready marker does not enable this package's
synthetic-only `ContactService`.

`feedback_ingress.py` exposes only `/feedback` on a separate private Unix socket.
The reviewed integration recipe reconstructs the allowlisted `63e4a33` worker,
applies its exact runtime/CLI patch and overlays these modules. Since TBX-11094
(October 17) that worker source is also in this tree, with both recorded patches
applied, so main builds and tests it. The in-tree Python equals the recipe's
`--with-backup` output except `recipient.py`, which carries the later TBX-9554 DNS
boundary fix; the recipe itself still reproduces the qualified artifact from
`63e4a33`. The two `*.disabled.json` manifests stay pinned to the reviewed candidate
`ae41af28`, which `gateway/deploy/private-contact/prepare.py` still accepts; a
future rollout pins its own admitted source. The service stays disabled. The local
acceptance exercises the reconstructed real worker, real encrypted journal and
the Tonebox receiver with reserved signed messages and captured SMTP.

See [the source, checks and future host packet](../docs/engineering/tbx-8936-feedback-integration/README.md)
for the reproducible recipe, immutable inputs, limits and unexecuted operating
qualification. The optional isolated-account group policy and updated local
worker artifact are recorded in [the group update](../docs/engineering/tbx-8936-feedback-integration/group-isolation.md).
The default remains same-UID owner-only admission. The local artifact has not
been admitted/deployed on the target, enabled a service, read production inputs
or established real mail delivery.

Signature order and hash selection follow the
[AWS SNS verification contract](https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message-verify-message-signature.html).
The SES scope and outcome fields follow
[AWS SES event contents](https://docs.aws.amazon.com/ses/latest/dg/event-publishing-retrieving-sns-contents.html).

Only bounded errors and aggregate counts belong in ordinary logs. Addresses,
grants, installation bearers, notice contents, provider payloads and private state
must not enter logs, public share rows or task evidence. Authenticated access proves
installation access, not legal identity. Already submitted mail cannot be recalled;
withdrawal blocks future delivery and invalidates private access. Unknown submission
is fenced and escalated rather than retried automatically.
