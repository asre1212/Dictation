# HIPAA deployment readiness

**Current status: development software requiring institutional assessment.** There is no claim of HIPAA compliance, certification, clinical validation, penetration testing or authorization for real patient information. This document maps the implemented design to remaining deployment work. A technical feature alone does not make a workflow compliant.

## Recommended deployment

Use the **Desktop** tab with local Whisper on an institution-managed Mac/Windows computer, through the local network or an approved private VPN. The app does not send audio or transcripts to Hugging Face; it downloads model assets. After the download, **Load cached** requires no external model access. The original cloud Dictate/keyboard mode is separate and needs its own vendor/BAA review, or removal from a clinical build.

| Area | Implemented in Desktop mode | Needed before clinical use |
|---|---|---|
| Transmission | TLS 1.2+, QR certificate pinning, random 256-bit session token, one phone per session | Test trust handling on real iOS hardware; security review/penetration testing; approve firewall and VPN setup |
| User access | iPhone device-owner authentication before pairing; desktop OS screen-lock/suspend teardown | Unique managed user accounts, device access policies, stronger desktop reauthentication/SSO if risk assessment requires it; lost-device revocation |
| Retention | No intentional audio/transcript files, no telemetry, bounded in-memory audio/retry cache; explicit draft clearing | Evaluate crash dumps, OS swap, backups, screen recording, notification leakage and forensic recovery; establish retention/disposal policies |
| At-rest protection | No clinical database | FileVault/BitLocker and iPhone passcode/data protection; MDM, patching, endpoint protection and remote wipe |
| Clipboard | Explicit copy, 2-minute clearing if clipboard remains unchanged | Disable/restrict cloud clipboard, Universal Clipboard and history/managers; approve Citrix clipboard policy; verify patient context |
| Sessions | 10-minute unclaimed QR expiry, 30-minute network inactivity expiry, 8-hour hard expiry, explicit end/clear | Tune timeout to institutional risk; test interruptions and abandoned devices |
| Auditability | No clinical text logged | Add institution-approved, access-controlled security/audit events: authenticated user, time, device/session, pairing/revocation, access, copy and failures. Avoid audio, transcript, token and patient identifiers in diagnostic logs. Set audit retention and review procedures |
| Software integrity | Versioned dependencies/model revisions, automated tests and platform build workflows | Signed Windows binaries, signed/notarized Mac app, signed iPhone distribution, SBOM/dependency review, vulnerability remediation process, controlled updates and rollback |
| Clinical integrity | Editable draft; explicit copy; no autonomous EMR write-back; no LLM rewriting | Held-out medical test set covering accents, room noise, negation, drug names, doses, numbers, units and GI terminology; define acceptable error thresholds and require clinician review |
| Vendor contracts | No hosted transcription/relay in local mode | Inventory every service that creates, receives, maintains or transmits ePHI on your behalf. Obtain BAAs when applicable, including infrastructure/VPN providers as appropriate; validate contractual/service scope |
| Governance | This readiness document | Named security/privacy officers, documented risk analysis and remediation, workforce training, acceptable-use/access policies, incident/breach response, contingency planning, periodic review and written approval |

## What encryption does not establish

HHS requires administrative, physical and technical safeguards appropriate to the regulated entity and its risks. Risk analysis is foundational. Encryption does not replace access control, auditability, integrity, availability, policies or vendor obligations. A cloud provider maintaining encrypted ePHI may still be a business associate even without the decryption key. Do not assume a service is exempt simply because a relay cannot read the content; assess its actual role and obtain legal/privacy review.

Downloading a public speech model is distinct from transmitting patient audio to a model-hosting/inference service. This local design reduces external processing, but does not eliminate endpoint, clipboard, network and organizational obligations.

The HHS Security Rule summary used here describes the currently effective rule and separately links the proposed modifications; proposed requirements have not been represented as already effective.

## Practical next steps

1. Give IT/security this repository, the local-mode data-flow description and a synthetic demonstration.
2. Select managed devices, approved networking and the allowed path into Epic/Citrix; exclude legacy cloud mode from the approved build unless separately cleared.
3. Complete/document the security risk analysis and assign the gaps above, including audit controls and signed distribution.
4. Validate clinical accuracy and failure modes on real iPhone/Mac/Windows hardware using non-patient test audio.
5. Obtain written institutional approval, then deploy through managed software distribution and monitor/maintain it.

## Primary references reviewed

1. [HHS: Summary of the HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/laws-regulations/index.html)
2. [HHS: Guidance on Risk Analysis](https://www.hhs.gov/hipaa/for-professionals/security/guidance/guidance-risk-analysis/index.html)
3. [HHS: Guidance on HIPAA and Cloud Computing](https://www.hhs.gov/hipaa/for-professionals/special-topics/health-information-technology/cloud-computing/index.html)
4. [HHS: Security Rule Guidance Material](https://www.hhs.gov/hipaa/for-professionals/security/guidance/index.html)
