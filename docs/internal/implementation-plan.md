# Implementation plan: UC Ward Announcements CDK stack

Status: **draft plan**, not implemented yet (2026-09-30; channels added 2026-10-03; rebranded from Shout and switched to QR code / JOIN keyword opt-in 2026-10-04; channels removed in favor of a single subscriber list 2026-10-04).

This plan turns the architecture in `README.md` / `AGENTS.md` into CDK code. It also covers the Lambda handlers, tests, and doc updates. The website side (`shout.parkernilson.dev`) is out of scope except where the two repos have to agree (message wording, keywords, callback URLs, CORS origins, stack outputs, API routes).

Guiding rule from both repos: **keep it simple.** One stack, one small table, a few small Lambdas, no VPC, no custom domains.

### What changed on 2026-10-04

- **Brand:** Shout → **UC Ward Announcements** (the University City Ward, San Diego, of The Church of Jesus Christ of Latter-day Saints). Every outgoing text starts with `UC Ward:`, e.g. announcements are `UC Ward: <announcement>`.
- **Opt-in:** printed **QR code posters** (with the disclosures) open the phone's messaging app with `JOIN` addressed to the toll-free number. Sign-up sheets, the verbal script, the invitation text, the YES confirmation, and dashboard "add receiver" are **gone**. Numbers only enter the system by texting JOIN.
- **No channels:** there is a single subscriber list. `JOIN` subscribes, STOP opts out, START resubscribes. There is no `LEAVE` keyword and no `channels` table; every announcement goes to every subscribed number.
- **Frequency:** disclosures say "message frequency may vary" instead of a monthly cap. "Message and data rates may apply" stays (carriers require it).
- **Names aren't collected** any more (a text only carries the phone number).
- Unchanged real-world names: the domain `shout.parkernilson.dev`, the repo names, and the existing SNS topic `shout-replies`.

---

## 1. Decisions at a glance

| Topic | Decision |
| ----- | -------- |
| Stacks | Single stack, renamed `CdkStack` → **`UcWardStack`** (nothing is deployed yet, so renaming is free). Termination protection on. |
| Existing resources | Phone number and `shout-replies` topic are **imported by ARN** (`sns.Topic.fromTopicArn`, plain ARN string for the number). The stack never creates or deletes them. The topic keeps its old name. |
| Lambda runtime / bundling | `NodejsFunction` (esbuild, already installed transitively; add it as an explicit devDependency), `Runtime.NODEJS_24_X`, `Architecture.ARM_64`, handlers written in TypeScript under `lambda/`. AWS SDK v3 is provided by the runtime and left external. |
| SMS sending | `@aws-sdk/client-pinpoint-sms-voice-v2` `SendTextMessage` with `OriginationIdentity` = the phone number ARN. IAM: `sms-voice:SendTextMessage` scoped to that ARN only. Only the reply handler and the announcement sender can send. |
| Opt-in | Inbound keyword only: `JOIN`. The reply handler subscribes the number and sends one confirmation. No outbound message is ever sent to a number that hasn't texted JOIN. |
| Subscribers | One list, no channels. Every announcement goes to every `subscribed` number. |
| Table | One DynamoDB table, **`receivers`**, on-demand, PITR on, deletion protection on, `RemovalPolicy.RETAIN`. PK `phoneNumber`, one item per number. No GSI. |
| Auth | Cognito user pool (`selfSignUpEnabled: false`, Essentials plan, `RETAIN`), Cognito domain with **newer managed login** + default branding, public app client (no secret, code + PKCE, `openid` `email`). |
| API | API Gateway **HTTP API** (`aws-apigatewayv2`) with `HttpUserPoolAuthorizer` as the **default authorizer**, CORS for prod + localhost, low stage throttling. |
| Announcements | API Lambda validates and **async-invokes** a sender Lambda (returns `202`). This avoids the 30 s HTTP API integration timeout and respects the toll-free ~3 msg/s throughput. The sender has `retryAttempts: 0` so a failure never double-sends. |
| Logs | CDK-managed log groups (feature flag already on), 1-month retention. Mask phone numbers in logs (`+1555***4567`). |

---

## 2. Target file layout

```
bin/cdk.ts                         # instantiate UcWardStack (renamed)
lib/
  config.ts                        # ARNs, phone number, URLs, domain prefix, contact email
  uc-ward-stack.ts                 # composes the constructs below + CfnOutputs
  constructs/
    tables.ts                      # receivers table
    reply-handler.ts               # Lambda + SNS subscription
    dashboard-auth.ts              # user pool, domain, branding, app client
    dashboard-api.ts               # HTTP API, authorizer, routes, dashboard Lambdas
lambda/
  reply-handler.ts
  dashboard/
    receivers.ts                   # GET/DELETE receivers (dispatch on routeKey)
    send-announcement.ts           # API-facing: validate + async invoke
  announcement-sender.ts           # worker: loops over the subscribed receivers
  shared/
    messages.ts                    # all outgoing SMS text (single source of truth here)
    keywords.ts                    # parse incoming text: JOIN, opt-out, opt-in, help, other
    phone.ts                       # E.164 normalize/validate, log masking
    receivers.ts                   # DynamoDB access for the receivers table
    sms.ts                         # SendTextMessage wrapper + opted-out error detection
    http.ts                        # JSON response helpers for API handlers
test/
  uc-ward-stack.test.ts            # template assertions
  lambda/*.test.ts                 # pure-logic unit tests
docs/internal/implementation-plan.md
```

`lib/cdk-stack.ts` and `test/cdk.test.ts` (starter template) are deleted.

The `receivers` Lambda serves both receiver routes and dispatches on `event.routeKey`, so there are two API Lambdas.

---

## 3. Configuration (`lib/config.ts`)

Plain constants, no context lookups:

```ts
export const config = {
  phoneNumber: '+18444933651',
  phoneNumberArn: 'arn:aws:sms-voice:us-west-1:445044180652:phone-number/phone-617c575d8efe4a21aa2a15f5222da64a',
  repliesTopicArn: 'arn:aws:sns:us-west-1:445044180652:shout-replies', // existing topic, keeps its old name
  contactEmail: 'parker.todd.nilson@gmail.com',
  siteOrigin: 'https://shout.parkernilson.dev',
  devOrigin: 'http://localhost:5173',
  cognitoDomainPrefix: 'ucward-parkernilson', // must be unique within us-west-1
};
```

Callback/sign-out URLs are the origins with a trailing `/`. Account/region continue to come from `.env` via `bin/cdk.ts`.

Guard in `UcWardStack`: if `this.region` is resolved and isn't `us-west-1`, throw. The imported ARNs only exist there.

---

## 4. Table (`lib/constructs/tables.ts`)

One `dynamodb.TableV2` with `billing: Billing.onDemand()`, `pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true }`, `deletionProtection: true`, and `removalPolicy: RETAIN`. CloudFormation names it, and the name is passed to Lambdas as `RECEIVERS_TABLE`.

**Decide the key schema before the first deploy.** Changing a key later means CloudFormation replaces the table, and with `RETAIN` that leaves the old table orphaned and the new one empty.

### `receivers`

One item per phone number. Items are only created by the reply handler, on JOIN.

- `partitionKey: { name: 'phoneNumber', type: STRING }`

| Who | Needs | How |
| --- | ----- | --- |
| Dashboard list, announcement sender, subscribed count | Every receiver | `Scan` (filter `status = subscribed` where needed). The list is one ward's worth of numbers, so a scan is fine. |
| Reply handler: JOIN / STOP / START | One number | `UpdateItem` by `phoneNumber` |
| Dashboard remove | One number | `UpdateItem` by `phoneNumber` |

Item shape (`lambda/shared/receivers.ts`):

| Attribute | Type | Notes |
| --------- | ---- | ----- |
| `phoneNumber` | S | Partition key. E.164, `+1XXXXXXXXXX` (US only; it's a US toll-free number) |
| `status` | S | `subscribed` \| `opted_out` \| `removed` |
| `firstJoinedAt` | S | First JOIN (`if_not_exists`). The consent record that backs the toll-free registration. |
| `lastJoinedAt` | S | Most recent JOIN |
| `joinMessageId` | S | `inboundMessageId` of the most recent JOIN text, as consent evidence |
| `optedOutAt` | S? | Last opt-out keyword seen or opted-out send error |
| `removedAt` | S? | Admin removal |
| `updatedAt` | S | Every write |

Only `status = subscribed` receives announcements. Removal is **soft** (`removed`), so the join record is kept for the registration.

Every opt-out path calls one helper, `markOptedOut(phone)` (in practice mostly the opted-out send error; see §5), which sets `status = opted_out` and `optedOutAt` with `ConditionExpression: attribute_exists(phoneNumber)` so an opt-out from an unknown number doesn't create an item. A later START restores `opted_out` → `subscribed` only; a `removed` number stays removed until it texts JOIN.

**Pagination:** `Scan` returns at most 1 MB per call. Every multi-item read in `shared/receivers.ts` (the dashboard list, `send-announcement`'s count, `announcement-sender`) must loop on `LastEvaluatedKey`, using `paginateScan` from `@aws-sdk/lib-dynamodb`. Add a unit test that feeds a mocked two-page response and expects both pages.

---

## 5. Reply handler (incoming SMS)

### Infra (`lib/constructs/reply-handler.ts`)

- `NodejsFunction` `lambda/reply-handler.ts`, 256 MB, 10 s timeout.
- `repliesTopic.addSubscription(new subs.LambdaSubscription(fn))` on the imported topic. This creates only an `AWS::SNS::Subscription` and a Lambda permission; the topic itself is untouched.
- Grants: `receivers.grantReadWriteData(fn)`, plus `sms-voice:SendTextMessage` on `config.phoneNumberArn`.
- Env: `RECEIVERS_TABLE`, `ORIGINATION_ARN`, `UC_WARD_NUMBER`.
- Optional: an SQS DLQ on the subscription (`deadLetterQueue`) so failed deliveries aren't lost silently. Cheap, and worth adding.

### Parsing (`lambda/shared/keywords.ts`)

`parse(messageBody)`: trim, uppercase, collapse whitespace, strip surrounding punctuation (`" join! "` → `JOIN`). Then:

| Text | Result |
| ---- | ------ |
| `JOIN` | `{ kind: 'join' }` |
| `STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT`, `OPTOUT`, `OPT-OUT`, `REVOKE`, `REMOVE` | `{ kind: 'optOut' }` |
| `START`, `UNSTOP` | `{ kind: 'optIn' }` |
| `HELP`, `INFO` | `{ kind: 'help' }` |
| anything else (including `JOIN` followed by more words, and `LEAVE`) | `{ kind: 'other' }` |

### Handler logic (`lambda/reply-handler.ts`)

For each SNS record, `JSON.parse(record.Sns.Message)`, which is End User Messaging's two-way payload: `originationNumber`, `destinationNumber`, `messageBody`, `messageKeyword`, `inboundMessageId`.

1. Ignore messages whose `destinationNumber` isn't `UC_WARD_NUMBER`. This is a defensive check.
2. `parse(messageBody)` and act:
   - **join**
     - Upsert the receiver: `status = subscribed`, `firstJoinedAt = if_not_exists(now)`, `lastJoinedAt = now`, `joinMessageId = inboundMessageId`, `updatedAt = now`. This applies whatever the previous status was (`removed`, `opted_out`): texting JOIN is a fresh opt-in.
     - Send `messages.joined`. If it fails with the opted-out error (the number is still blocked after a STOP; see Q1), set the receiver back to `opted_out` and stop.
     - A JOIN from a number that's already subscribed does the same thing (refreshes `lastJoinedAt`, resends the confirmation). That's idempotent and reassures the person.
   - **optOut** → `markOptedOut(phone)`. **No reply.** The carrier sends the confirmation.
   - **optIn** (`START`/`UNSTOP`) → if the receiver is `opted_out`, set it back to `subscribed` (it was subscribed before STOP, and START is an explicit re-opt-in). A `removed` or unknown number is unchanged. No reply; the carrier sends its own confirmation. Verify during the smoke test that these messages reach the topic (Q1).
   - **help** → no reply. AWS sends the configured HELP response.
   - **other** → send `messages.otherReply`. Don't change the table. (Most of these will be people replying to an announcement.)
3. Every send goes through `shared/sms.ts`. If it fails with the opted-out conflict (`ConflictException`, reason `DESTINATION_PHONE_NUMBER_OPTED_OUT`), call `markOptedOut` and continue. Any other error is thrown so SNS retries it.

**Opt-outs are managed by the carrier and AWS, not by this stack.** On a US toll-free number, STOP is handled at the carrier level, and AWS End User Messaging adds the number to its opt-out list. With the default settings (self-managed opt-outs **off**), STOP and HELP are most likely never routed to `shout-replies`, so the reply handler's `optOut`/`optIn` branches may never run. That's fine: AWS and the carrier block sends to an opted-out number whatever the table says, so the table can't cause an unwanted text. The table catches up when a send fails with the opted-out error (step 3), which calls `markOptedOut`. Keep it that way: **don't enable self-managed opt-outs** (that would make this stack responsible for honoring STOP and HELP) and don't add a separate sync against AWS's opt-out list. The `optOut`/`optIn` branches stay as a harmless fallback in case those messages do arrive. The dashboard may show a number as `subscribed` until the next announcement after it texted STOP.

Redeliveries are safe: the table updates are idempotent, and at worst a reply is sent twice.

---

## 6. Outgoing messages (`lambda/shared/messages.ts`)

This is the only file that holds SMS wording. Every message starts with `UC Ward:`. Contact is email-only. No message states a monthly cap; frequency "varies". Every message the handler sends unprompted by a keyword (announcements, `otherReply`) includes STOP wording; the JOIN confirmation carries the full disclosures.

```ts
// MUST match `joinConfirmation` in shout.parkernilson.dev/src/lib/config.ts
// and the AWS toll-free registration. Change all three together.
export const joined =
  "UC Ward: You're subscribed to announcements from UC Ward Announcements. Msg frequency varies. Msg & data rates may apply. Reply HELP for help, STOP to opt out.";

export const otherReply =
  'UC Ward: This number only sends announcements. Text JOIN to subscribe or STOP to opt out. Questions? Email parker.todd.nilson@gmail.com.';

// Announcements: "UC Ward: <body>", adding the prefix if missing, and appending
// " Reply STOP to opt out." if the text doesn't already contain STOP. The admin can't produce
// a message without opt-out wording.
export function announcement(body: string): string;
```

Max announcement length: validate in the API, for example 320 characters for the final text including the prefix and suffix, which is at most 3 GSM-7 segments. Reject an empty or too-long message with `400`.

A unit test asserts that `joined` equals the website's `joinConfirmation()` output exactly. The string is copied into the test rather than imported across repos.

---

## 7. Dashboard auth (`lib/constructs/dashboard-auth.ts`)

```ts
const userPool = new cognito.UserPool(this, 'UserPool', {
  selfSignUpEnabled: false,
  signInAliases: { email: true },
  autoVerify: { email: true },
  featurePlan: cognito.FeaturePlan.ESSENTIALS,
  accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
  mfa: cognito.Mfa.OPTIONAL,                       // see Q3
  mfaSecondFactor: { otp: true, sms: false },
  passwordPolicy: { minLength: 12 },
  deletionProtection: true,
  removalPolicy: RemovalPolicy.RETAIN,
});

const client = userPool.addClient('DashboardClient', {
  generateSecret: false,
  preventUserExistenceErrors: true,
  supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
  oAuth: {
    flows: { authorizationCodeGrant: true },        // PKCE is enforced client-side by Amplify
    scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL],
    callbackUrls: ['https://shout.parkernilson.dev/', 'http://localhost:5173/'],
    logoutUrls:   ['https://shout.parkernilson.dev/', 'http://localhost:5173/'],
  },
});

const domain = userPool.addDomain('Domain', {
  cognitoDomain: { domainPrefix: config.cognitoDomainPrefix },
  managedLoginVersion: cognito.ManagedLoginVersion.NEWER_MANAGED_LOGIN,
});

new cognito.CfnManagedLoginBranding(this, 'Branding', {
  userPoolId: userPool.userPoolId,
  clientId: client.userPoolClientId,
  useCognitoProvidedValues: true,   // newer managed login shows nothing without a branding style
});
```

The stack creates no users. Admins are created by hand (see §11).

Output the Cognito domain **as a host without `https://`**, `ucward-parkernilson.auth.us-west-1.amazoncognito.com`, because Amplify's `loginWith.oauth.domain` expects that form.

---

## 8. Dashboard API (`lib/constructs/dashboard-api.ts`)

```ts
const authorizer = new HttpUserPoolAuthorizer('CognitoAuthorizer', userPool, {
  userPoolClients: [client],   // audience = app client ID (HTTP API also checks client_id in access tokens)
});

const api = new apigwv2.HttpApi(this, 'DashboardApi', {
  defaultAuthorizer: authorizer,             // every route requires the JWT
  corsPreflight: {
    allowOrigins: [config.siteOrigin, config.devOrigin],
    allowHeaders: ['Authorization', 'Content-Type'],
    allowMethods: [GET, POST, DELETE, OPTIONS],
    maxAge: Duration.hours(1),
  },
});
// Default stage throttling: e.g. rateLimit 5, burstLimit 10 (via the CfnStage escape hatch or defaultStage options).
```

With `corsPreflight` set, API Gateway answers `OPTIONS` without invoking the authorizer. Don't add `ANY /{proxy+}` or explicit `OPTIONS` routes, because they would capture preflight.

### Routes

| Method & path | Lambda | Behavior |
| ------------- | ------ | -------- |
| `GET /receivers` | `receivers` | Scan the table and return each receiver's `phoneNumber`, `status`, and timestamps, including `removed`/`opted_out`. The dashboard filters/sorts. |
| `DELETE /receivers/{phoneNumber}` | `receivers` | `decodeURIComponent` the path param and normalize it. `404` if the receiver is missing. Set `status = removed`, `removedAt`, unless it's `opted_out`, which stays `opted_out` so the opt-out isn't hidden. No SMS. The person can rejoin by texting JOIN again. |
| `POST /announcements` `{ message }` | `send-announcement` | Build the final text with `messages.announcement(message)` and validate its length. Count the `subscribed` receivers, async-invoke `announcement-sender` with `{ text }`, and return `202 { recipients, preview }`. |

There is **no "add receiver" route**: numbers only join by texting JOIN, which is the only opt-in the posters and registration describe.

### Lambdas and grants

| Lambda | Grants |
| ------ | ------ |
| `receivers` | receivers table read/write |
| `send-announcement` | receivers table read, `lambda:InvokeFunction` on the sender |

No dashboard Lambda can send SMS directly.

**`announcement-sender`** (not an API route): 512 MB, 15 min timeout, `retryAttempts: 0`, `reservedConcurrentExecutions: 1`, so two announcements never interleave and exceed throughput. If a second announcement arrives while one is sending, the async invoke is throttled and Lambda retries it later, up to the 6-hour max event age. The sender scans the `subscribed` receivers and sends one at a time at ~2 msg/s (`await sleep(500)`). An opted-out error calls `markOptedOut`. It logs a summary (sent / opted out / failed). Grants: receivers table read/write and `SendTextMessage`.

All API handlers return JSON via `shared/http.ts`. They log the Cognito `sub`/email from `event.requestContext.authorizer.jwt.claims` for an audit trail.

---

## 9. Stack outputs

`CfnOutput`s in `UcWardStack`, which the website copies into `src/lib/config.ts`:

| Output | Value |
| ------ | ----- |
| `UserPoolId` | `userPool.userPoolId` |
| `UserPoolClientId` | `client.userPoolClientId` |
| `CognitoDomain` | `${prefix}.auth.us-west-1.amazoncognito.com` |
| `ApiUrl` | `api.apiEndpoint` (no trailing slash) |
| `ReceiversTableName` | for console/CLI use |

---

## 10. Tests

### `test/uc-ward-stack.test.ts` (template assertions, `aws-cdk-lib/assertions`)

Synthesize `UcWardStack` once with `env: { account: '445044180652', region: 'us-west-1' }`. Then check:

- **No** `AWS::SNS::Topic` or `AWS::SMSVOICE::PhoneNumber` resources (existing ones are never created).
- `AWS::SNS::Subscription` with `Protocol: lambda` and `TopicArn` = the `shout-replies` ARN.
- Exactly one `AWS::DynamoDB::GlobalTable`: key schema `phoneNumber` HASH, no GSIs, PITR on, deletion protection on, `DeletionPolicy: Retain`, `UpdateReplacePolicy: Retain`.
- User pool: `AdminCreateUserConfig.AllowAdminCreateUserOnly: true`.
- App client: `GenerateSecret: false`, `AllowedOAuthFlows: ['code']`, scopes `openid` + `email`, exact callback/logout URLs.
- **Every** `AWS::ApiGatewayV2::Route` has `AuthorizationType: JWT` (iterate `findResources`, so new routes are covered automatically), and there is no `POST /receivers` route.
- Authorizer `JwtConfiguration` issuer/audience reference the pool/client.
- API CORS origins, headers, and methods as specified.
- Every IAM statement with `sms-voice:SendTextMessage` has `Resource` = the phone number ARN (no `*`), and only the reply handler's and sender's roles have it.
- The five outputs exist.

`NodejsFunction` bundling runs esbuild during synth in tests. That's acceptable for this size of project; there is no Docker dependency because esbuild is local.

### `test/lambda/*.test.ts` (pure logic)

- `keywords`: `JOIN`, ` join! ` → join; `JOIN RS`, `LEAVE` → other; every opt-out/opt-in/help keyword; random text → other.
- `phone`: normalization and rejection cases.
- `messages`: `joined` equals the website's `joinConfirmation()` (literal copy); every message starts with `UC Ward: `; `announcement()` always contains `STOP` and fits the length limit; no message contains `msgs/mo` (frequency varies); no message contains a phone number (contact is email-only).
- Pagination: a mocked two-page `Scan` returns items from both pages.
- Handlers: inject the DynamoDB/SMS helpers (or use `aws-sdk-client-mock` if cleaner) and cover:
  - reply handler: `JOIN` → receiver `subscribed` + `joined`; JOIN after removal → `subscribed` again with `firstJoinedAt` unchanged; STOP → `opted_out`, no send; STOP from an unknown number → no item created; START → `opted_out` back to `subscribed` (a `removed` one stays `removed`), no send; other (including `LEAVE`) → one `otherReply`, no write; opted-out send error on JOIN → `opted_out`.
  - receivers: remove → `removed`; remove of an `opted_out` receiver stays `opted_out`.

No `jest.config.js` change is needed; it already picks up `test/**/*.test.ts`.

---

## 11. Implementation phases

Each phase ends with `npm run build`, `npm run test`, and `npx cdk synth` passing, plus doc updates (a repo rule).

1. **Scaffold.** Rename the stack to `UcWardStack` (`bin/cdk.ts`, `lib/uc-ward-stack.ts`) and add `lib/config.ts`. Add devDependencies: `esbuild`, `@types/aws-lambda`, `@aws-sdk/client-dynamodb`, `@aws-sdk/lib-dynamodb`, `@aws-sdk/client-pinpoint-sms-voice-v2`. Delete the starter test.
2. **Tables + shared libs.** `tables.ts`, `lambda/shared/*`, and their unit tests.
3. **Reply handler.** Construct, handler, SNS subscription, tests.
4. **Cognito.** `dashboard-auth.ts`, outputs, tests.
5. **API + dashboard Lambdas.** `dashboard-api.ts`, the two route Lambdas, the sender worker, tests.
6. **Docs.** In `README.md` / `AGENTS.md`, move components from *planned* to done, rename `lib/cdk-stack.ts` references, document routes, outputs, and the admin-user command, and add `lambda/` to the project structure. Tell the website repo which values to put in its config and that the dashboard needs a receiver list (with remove) and an announcement form, and no add-receiver form.

### First deploy checklist (manual, done by Parker)

- `npx cdk bootstrap aws://445044180652/us-west-1` (once).
- `npx cdk deploy`, then copy the outputs into the website's `src/lib/config.ts`.
- Create an admin: `aws cognito-idp admin-create-user --user-pool-id <id> --username <email> --user-attributes Name=email,Value=<email> Name=email_verified,Value=true`.
- In End User Messaging, confirm on the number: two-way SMS → `shout-replies`; the HELP keyword response includes the contact email and the JOIN/STOP keywords (e.g. `UC Ward: Text JOIN to subscribe, STOP to opt out. Help: parker.todd.nilson@gmail.com. Msg & data rates may apply.`); no custom keyword is configured for `JOIN` (it must reach the handler, not get an AWS auto-response). Also confirm that the topic's access policy lets `sms-voice.amazonaws.com` publish; the stack doesn't manage that policy.
- Print posters with a QR code for `SMSTO:+18444933651:JOIN` next to the website's `posterDisclosure()` text and the line "Scan the code or text JOIN to +1 (844) 493-3651". Test-scan each with both an iPhone and an Android phone before printing in bulk.
- Update the toll-free registration's opt-in workflow: QR code poster → user-initiated JOIN text → confirmation. Attach a photo or PDF of the poster and link the prerendered site.
- Smoke test with Parker's own phone: scan the poster and send JOIN (`subscribed`, confirmation reads `UC Ward: You're subscribed...`) → send an announcement (message reads `UC Ward: ...`) → a random text (`otherReply`) → STOP (`opted_out`) → START (`subscribed` again) → remove the number in the dashboard (`removed`) → JOIN (`subscribed`, `firstJoinedAt` unchanged). Check the table after each step.
- Toll-free registration is still pending. Outbound sends may be blocked or throttled until it's approved.

---

## 12. Open questions (recommendations in bold)

- **Q1. JOIN after STOP.** On toll-free numbers, STOP blocks the number at the carrier, and only START/UNSTOP lifts it, so a JOIN from a stopped number reaches the handler but the confirmation fails as opted out. The plan handles that by leaving the receiver `opted_out`. **Recommend** the posters and site keep telling people to reply START to opt back in (already on the site), and verifying in the smoke test (a) whether START/UNSTOP reach the SNS topic and (b) whether AWS's opt-out list is cleared by START. If START doesn't reach the topic, a later JOIN can't recover the number automatically; consider `DeleteOptedOutNumber` on JOIN only if AWS documents that as allowed for user-initiated re-opt-in.
- **Q2. Message frequency.** The advertised wording is "message frequency may vary", with no monthly cap. **Recommend** using the same wording in the toll-free registration's message-volume and sample-message fields, and no enforcement in code.
- **Q3. MFA for admins.** **Recommend `Mfa.REQUIRED` with TOTP.** It's cheap and the dashboard can message every subscriber. Kept `OPTIONAL` above until confirmed.
- **Q4. Announcement history.** **Recommend skipping** for now: CloudWatch logs of the sender are enough. A small `announcements` table can be added later if the dashboard wants history.
- **Q5. Domain and topic names.** The site is still at `shout.parkernilson.dev` and the topic is `shout-replies`. **Recommend** leaving the topic name (it's never user-visible). If the domain moves before the toll-free registration is resubmitted, change `config.siteOrigin`, the Cognito callback/logout URLs, CORS origins, and the website's `site.url`/`static/CNAME` together, and reprint the posters.
