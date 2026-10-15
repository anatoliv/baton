# Private contact domain preparation

This disconnected package models optional installation-bound verified contact and
case-specific notice orchestration. It has no production mode, HTTP server,
native wiring, filesystem/database adapter, SES sending adapter, credentials or keys.
The standalone `sns_feedback.py` admission adapter verifies original SNS
Notifications; it is disconnected from the service and has no synthetic marker.
`ContactService` defaults disabled. The only accepted mode is `synthetic`, with
all injected adapters explicitly marked synthetic and a synthetic consent version.
These markers prevent accidental ordinary construction; they are not a security
attestation or a substitute for deployment controls. Never connect this mode to
real identities, secrets, provider transport or operator cases.

Run the isolated reserved-data acceptance from the repository root:

```sh
python3 -m unittest private_contact.tests.test_delivery -v
```

The tests call service boundaries and observe captured mail, authorized private
readback and public status. They do not inspect private storage fields to certify
behavior. The in-memory transactional fixture survives replacement of the service
object and serializes threads. This is a service-restart simulation, not evidence
of disk persistence, encryption, process failure durability or backup recovery.

## Required adapters before any future production implementation

- `custody.transact(operation)` must commit a deep-isolated private state and
  returned result atomically and serialize every process. Its schema includes
  contacts, coverage/consent, keyed challenges, rates, jobs, grants, minimal
  provider references, transition history and private escalations. Failed commits
  before submission must send nothing; failed commits after possible submission
  must leave a durable dispatch lease which becomes unknown, never retry blindly.
  `custody.reconciled()` must stay false after restore until withdrawals, expiry,
  consent revisions and authoritative action history are reconciled. Its boolean
  is an injected dependency, not an implemented restore verifier.
- `authority.installation(proof, purpose, utc)` returns only an authorized private
  installation handle. A production adapter must validate a single-use,
  purpose-bound, short-lived bridge authorization, with replay protection and
  authenticated service transport. No raw installation bearer enters this package.
  Verification and access must independently authorize the same installation.
  `authority.owned(proof, shares, utc)` must prove any historical coverage using
  the existing owner-list boundary; public share/key possession is insufficient.
- `authority.case(review, utc, scope)` admits only a separately reviewed private
  operation and its exact installation/case/action/revision/share/creation-time
  and notice snapshot. `current_case(scope, utc)` must revalidate current case
  authorization immediately before sending/access. Notice correctness, reviewed
  legal instructions, redacted location without fragments, expiry, recall and
  restoration limits remain the private reviewer/adapter's obligations. A boolean
  synthetic authority does not establish any of these production facts.
- `authority.recipient(address)` must validate the approved recipient policy and
  actual domain mail capability, including null-MX refusal. No live DNS check is
  supplied. Reserved `.invalid` recipients work only in the captured-mail fixture.
- `secrets.random()` must supply collision-resistant, cryptographically random
  codes/references. `secrets.verifier(purpose, value)` must supply domain-separated
  keyed verifiers with qualified private key custody and rotation. The only key
  in tests is public fixture text; no actual key is created or read.
- `mail.send(message)` consumes only a generic verification/notice template,
  recipient and typed code. It returns `accepted` with a provider reference,
  confirmed pre-acceptance `transient`, `permanent`, or `unknown`. Arbitrary
  exceptions, malformed results and ambiguous acceptance become unknown.
  The production template must include consent purpose, originating-app entry,
  expiry and approved reply/intake route without notice details or sensitive URLs.
  An SES SMTP/API adapter must distinguish pre-acceptance failure from possible
  DATA/API acceptance and retain only private minimum evidence. No such adapter
  exists here; the quota-alert sender stays operator-only.
- `feedback.admit(envelope)` must validate the actual approved transport/signature,
  body limits, provider/account/sending scope and canonical event identity before
  returning only `event`, `message`, `outcome`. It must strip recipients, headers,
  bodies and reject malformed/orphan/foreign callbacks without logging payloads.
  The orchestration deduplicates events and correlates only known accepted sends.
  Unknown sends lacking a recoverable provider reference require operator recovery
  and escalation; this package does not pretend to recover SES exactly-once sends.

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
applies its exact runtime/CLI patch and overlays these modules. Main's domain
service remains disabled; the retained worker is not blindly merged. The local
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

Only aggregate integers and bounded error categories are suitable for ordinary
logs/tasks. Internal bounded refusals have a separate exception type; arbitrary
adapter errors, including adapter-thrown public `Denied`, become `unavailable`. `private_job` requires operator authorization and returns private
state/history/escalation readback without notice, code or grant. Even these private
per-case transitions must not be emitted to ordinary logs. The private notice
itself is returned only through current installation authorization plus its live
case grant; no public/enforcement or owner-list schema is extended.

## Synthetic policy bounds and limits

The acceptance model uses the prepared proposals: 15-minute challenge, five
guesses, one pending challenge, three enrollment sends per hour per installation
and keyed mailbox, global 100/hour, verified replacements, 90-day route review,
24-hour grants and disconnected-address expiry, two-minute dispatch leases,
three confirmed-transient attempts within four hours with 60/600-second delays,
with the age bound checked before leasing and again immediately before submission,
30-minute missing receipt and four-hour access escalation. It additionally models
20 case-access attempts per installation per hour, and refuses conflicting
creation-time snapshots under an existing job identity. These are simulation
bounds for review, not adopted production policy or provider quotas.

Withdrawal blocks queued/future delivery and invalidates access. A generic mail
whose submission already began can still arrive; it cannot be recalled. The
in-flight-withdrawal test observes this boundary and verifies stale completion
cannot reopen access. Late failure feedback disables only the matching current
contact revision and preserves its private history. A later delivery event does
not resurrect withdrawn routes or erase escalations.

Escalation here means a record available in restricted private custody and
operator readback. It does not establish a monitored destination, backup staff,
acknowledgement or manual delivery. Receipt versus access observations remain
separate; authenticated access proves installation access, never legal identity.
No tracking pixel, read receipt or public case URL is introduced.

Active case/feedback/rate history beyond the modeled expiry behavior is not
production retention code. The selected encrypted store must implement approved
case closure/preservation, erasure and encrypted-backup lifecycle before a
production mode can be added. Future production admission also needs bounds for
case-job/global dispatch rates and private state size, real schema migrations,
clock handling, two-process locking and crash-safe commit fault acceptance.
