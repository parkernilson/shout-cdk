# Implementation plan: Shout CDK stack

Status: **draft plan**, not implemented yet (2026-09-30, channels added 2026-10-03).

This plan turns the architecture in `README.md` / `AGENTS.md` into CDK code. It also covers the Lambda handlers, tests, and doc updates. The website side (`shout.parkernilson.dev`) is out of scope except where the two repos have to agree (message wording, callback URLs, CORS origins, stack outputs, API routes).

Guiding rule from both repos: **keep it simple.** One stack, two small tables, a few small Lambdas, no VPC, no custom domains.

---

## 1. Decisions at a glance

| Topic | Decision |
| ----- | -------- |
| Stacks | Single stack, renamed `CdkStack` → **`ShoutStack`** (nothing is deployed yet, so renaming is free). Termination protection on. |
| Existing resources | Phone number and `shout-replies` topic are **imported by ARN** (`sns.Topic.fromTopicArn`, plain ARN string for the number). The stack never creates or deletes them. |
| Lambda runtime / bundling | `NodejsFunction` (esbuild, already installed transitively; add it as an explicit devDependency), `Runtime.NODEJS_24_X`, `Architecture.ARM_64`, handlers written in TypeScript under `lambda/`. AWS SDK v3 is provided by the runtime and left external. |
| SMS sending | `@aws-sdk/client-pinpoint-sms-voice-v2` `SendTextMessage` with `OriginationIdentity` = the phone number ARN. IAM: `sms-voice:SendTextMessage` scoped to that ARN only. |
| Channels | Admins create, rename, and archive channels in the dashboard. A phone number can belong to **several channels**. Announcements go to one channel at a time. |
| Tables | Two DynamoDB tables, both on-demand, PITR on, deletion protection on, `RemovalPolicy.RETAIN`. **`channels`**: PK `channelId`. **`receivers`** (one item per channel membership): PK `channelId`, SK `phoneNumber`, GSI **`byPhone`** (PK `phoneNumber`, SK `channelId`) for incoming SMS, which only carry the phone number. |
| Auth | Cognito user pool (`selfSignUpEnabled: false`, Essentials plan, `RETAIN`), Cognito domain with **newer managed login** + default branding, public app client (no secret, code + PKCE, `openid` `email`). |
| API | API Gateway **HTTP API** (`aws-apigatewayv2`) with `HttpUserPoolAuthorizer` as the **default authorizer**, CORS for prod + localhost, low stage throttling. |
| Announcements | API Lambda validates and **async-invokes** a sender Lambda (returns `202`). This avoids the 30 s HTTP API integration timeout and respects the toll-free ~3 msg/s throughput. The sender has `retryAttempts: 0` so a failure never double-sends. |
| Logs | CDK-managed log groups (feature flag already on), 1-month retention. Mask phone numbers in logs (`+1555***4567`). |

---

## 2. Target file layout

```
bin/cdk.ts                         # instantiate ShoutStack (renamed)
lib/
  config.ts                        # ARNs, phone number, URLs, domain prefix, contact email
  shout-stack.ts                   # composes the constructs below + CfnOutputs
  constructs/
    tables.ts                      # channels + receivers tables (and the byPhone GSI)
    reply-handler.ts               # Lambda + SNS subscription
    dashboard-auth.ts              # user pool, domain, branding, app client
    dashboard-api.ts               # HTTP API, authorizer, routes, dashboard Lambdas
lambda/
  reply-handler.ts
  dashboard/
    channels.ts                    # GET/POST/PATCH/DELETE channels (dispatch on routeKey)
    receivers.ts                   # GET/POST/DELETE receivers within a channel
    send-announcement.ts           # API-facing: validate + async invoke
  announcement-sender.ts           # worker: loops over a channel's subscribed receivers
  shared/
    messages.ts                    # all outgoing SMS text (single source of truth here)
    keywords.ts                    # normalize incoming text, classify YES / opt-out / opt-in / help / other
    phone.ts                       # E.164 normalize/validate, log masking
    channels.ts                    # DynamoDB access for the channels table
    receivers.ts                   # DynamoDB access for receivers (by channel, by phone via byPhone)
    sms.ts                         # SendTextMessage / DescribeOptedOutNumbers wrappers + opted-out error detection
    http.ts                        # JSON response helpers for API handlers
test/
  shout-stack.test.ts              # template assertions
  lambda/*.test.ts                 # pure-logic unit tests
docs/internal/implementation-plan.md
```

`lib/cdk-stack.ts` and `test/cdk.test.ts` (starter template) are deleted.

Each dashboard Lambda serves a group of routes and dispatches on `event.routeKey`. That gives three API Lambdas instead of eight, and IAM grants still differ where they need to (only `receivers` can send SMS).

---

## 3. Configuration (`lib/config.ts`)

Plain constants, no context lookups:

```ts
export const config = {
  phoneNumber: '+18444933651',
  phoneNumberArn: 'arn:aws:sms-voice:us-west-1:445044180652:phone-number/phone-617c575d8efe4a21aa2a15f5222da64a',
  optOutListName: 'Default', // confirm in End User Messaging (see Q9)
  repliesTopicArn: 'arn:aws:sns:us-west-1:445044180652:shout-replies',
  contactEmail: 'parker.todd.nilson@gmail.com',
  siteOrigin: 'https://shout.parkernilson.dev',
  devOrigin: 'http://localhost:5173',
  cognitoDomainPrefix: 'shout-parkernilson', // must be unique within us-west-1
};
```

Callback/sign-out URLs are the origins with a trailing `/`. Account/region continue to come from `.env` via `bin/cdk.ts`.

Guard in `ShoutStack`: if `this.region` is resolved and isn't `us-west-1`, throw. The imported ARNs only exist there.

---

## 4. Tables (`lib/constructs/tables.ts`)

Both tables are `dynamodb.TableV2` with `billing: Billing.onDemand()`, `pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true }`, `deletionProtection: true`, and `removalPolicy: RETAIN`. CloudFormation names them, and the names are passed to Lambdas as `CHANNELS_TABLE` / `RECEIVERS_TABLE`.

**Decide the key schemas before the first deploy.** Changing a key later means CloudFormation replaces the table, and with `RETAIN` that leaves the old table orphaned and the new one empty.

### `channels`

- `partitionKey: { name: 'channelId', type: STRING }`

| Attribute | Type | Notes |
| --------- | ---- | ----- |
| `channelId` | S | `crypto.randomUUID()`. Key values can't change, so the key is an opaque ID. That way a rename is a one-item update, not a rewrite of every receiver. |
| `name` | S | Shown in the dashboard. 1–40 chars, trimmed, unique among `active` channels (checked in the handler). |
| `status` | S | `active` \| `archived` |
| `createdAt`, `updatedAt` | S | ISO timestamps |
| `archivedAt` | S? | |

Archiving is a **soft delete**. Receivers in the channel are kept (they're the opt-in records), but the channel can't get new receivers or announcements.

### `receivers`

One item per **(channel, phone number)** membership.

- `partitionKey: { name: 'channelId', type: STRING }`, `sortKey: { name: 'phoneNumber', type: STRING }`
- GSI `byPhone`: `partitionKey: phoneNumber`, `sortKey: channelId`, `projectionType: ALL` (items are tiny)

How each access pattern is served:

| Who | Needs | How |
| --- | ----- | --- |
| Dashboard list, announcement sender | Everyone in a channel | `Query channelId = :id` on the table |
| Reply handler, add-receiver checks | Every channel a number belongs to | `Query phoneNumber = :p` on `byPhone` |
| Add/remove one receiver | One membership | `GetItem` / `UpdateItem` by `(channelId, phoneNumber)` |

The GSI is eventually consistent. It usually lags by well under a second, which doesn't matter here: a YES arrives long after the invitation write. Writes always go to the table by full key, with `ConditionExpression: attribute_exists(phoneNumber)` so a stale GSI read can't create a stray item.

Item shape (`lambda/shared/receivers.ts`):

| Attribute | Type | Notes |
| --------- | ---- | ----- |
| `channelId` | S | Partition key |
| `phoneNumber` | S | Sort key. E.164, `+1XXXXXXXXXX` (US only; it's a US toll-free number) |
| `name` | S | Person's name, required, 1–100 chars. Stored per membership, so it's duplicated across channels; that's fine at this size. |
| `status` | S | `invited` \| `subscribed` \| `opted_out` \| `removed` |
| `invitedAt` | S? | ISO timestamp, set only on the membership whose add actually sent the invitation text |
| `subscribedAt` | S? | When this membership became `subscribed` (kept with `if_not_exists`). The number's original consent is the earliest `subscribedAt` across its memberships, which backs the toll-free registration. |
| `lastYesAt` | S? | Most recent YES |
| `optedOutAt` | S? | Last opt-out keyword seen or opted-out send error |
| `removedAt` | S? | Admin removal |
| `updatedAt` | S | Every write |

Removal is a **soft delete** (`status = removed`), so sign-up/YES records are kept for the registration. Only `status = subscribed` receives announcements.

**Opt-out is per number, not per channel.** STOP opts a number out of the whole toll-free number at the carrier, so every opt-out path calls one helper, `markOptedOut(phone)`. It queries `byPhone` and sets every non-`removed` membership to `opted_out`.

**Pagination:** `Scan` and `Query` return at most 1 MB per call. Every multi-item read in `shared/channels.ts` and `shared/receivers.ts` (the dashboard lists, `byPhone` lookups, `send-announcement`'s count, `announcement-sender`) must loop on `LastEvaluatedKey`, using `paginateScan` / `paginateQuery` from `@aws-sdk/lib-dynamodb`. Otherwise the dashboard and announcements would silently stop at the first page once the tables grow. Add a unit test that feeds a mocked two-page response and expects both pages.

---

## 5. Reply handler (incoming SMS)

### Infra (`lib/constructs/reply-handler.ts`)

- `NodejsFunction` `lambda/reply-handler.ts`, 256 MB, 10 s timeout.
- `repliesTopic.addSubscription(new subs.LambdaSubscription(fn))` on the imported topic. This creates only an `AWS::SNS::Subscription` and a Lambda permission; the topic itself is untouched.
- Grants: `receivers.grantReadWriteData(fn)` (also covers the `byPhone` index), plus `sms-voice:SendTextMessage` on `config.phoneNumberArn`.
- Env: `RECEIVERS_TABLE`, `ORIGINATION_ARN`, `SHOUT_NUMBER`.
- Optional: an SQS DLQ on the subscription (`deadLetterQueue`) so failed deliveries aren't lost silently. Cheap, and worth adding.

### Handler logic (`lambda/reply-handler.ts`)

For each SNS record, `JSON.parse(record.Sns.Message)`, which is End User Messaging's two-way payload: `originationNumber`, `destinationNumber`, `messageBody`, `messageKeyword`, `inboundMessageId`.

1. Ignore messages whose `destinationNumber` isn't `SHOUT_NUMBER`. This is a defensive check.
2. Look up the sender's memberships: `Query byPhone` for `originationNumber`.
3. `classify(messageBody)` in `shared/keywords.ts`: trim, uppercase, strip surrounding punctuation/whitespace (`"yes!"`, `" Yes."` → `YES`).
   - **YES**
     - No memberships → treat as **anything else** (see Q5). There's no channel to add them to.
     - Any membership `opted_out` → ignore (Q2). Sends would be blocked anyway.
     - Otherwise every `invited` membership → `status = subscribed`, `subscribedAt = if_not_exists(now)`, `lastYesAt = now`. Every `subscribed` membership → `lastYesAt = now`. `removed` is untouched. One YES confirms all pending invitations, because the invitation text doesn't name a channel.
   - **Opt-out** (`STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT`, `OPTOUT`, `OPT-OUT`, `REVOKE`) → `markOptedOut(phone)`. **No reply.** The carrier sends the confirmation.
   - **Opt-in** (`START`, `UNSTOP`) → no reply (carrier-handled); status handling per Q2.
   - **HELP** (`HELP`, `INFO`) → no reply. AWS sends the configured HELP response.
   - **Anything else** → send `messages.otherReply` (contact email + STOP instructions). Do not change the table.
4. Every send goes through `shared/sms.ts`. If it fails with the opted-out conflict (`ConflictException`, reason `DESTINATION_PHONE_NUMBER_OPTED_OUT`), call `markOptedOut` and continue. Any other error is thrown so SNS retries it.

Redeliveries are safe: the table updates are idempotent, and at worst the "anything else" reply is sent twice.

---

## 6. Outgoing messages (`lambda/shared/messages.ts`)

This is the only file that holds SMS wording. Every message starts with `Shout`, includes STOP wording, and gives email-only contact.

```ts
// MUST match `confirmationMessage` in shout.parkernilson.dev/src/lib/config.ts
// and the AWS toll-free registration. Change all three together.
export const invitation =
  'Shout: Reply YES to get local community announcements & reminders. Up to 4 msgs/mo. Msg & data rates may apply. Reply HELP for help, STOP to opt out.';

export const otherReply =
  'Shout: To reach Parker Nilson, email parker.todd.nilson@gmail.com. Reply STOP to opt out of messages.';

// Announcements: prefix "Shout: " (or "Shout (<channel name>): ", see Q7) if missing, append
// " Reply STOP to opt out." if the text doesn't already contain STOP. The admin can't produce
// a message without opt-out wording.
export function announcement(channelName: string, body: string): string;
```

Max announcement length: validate in the API, for example 320 characters for the final text including the prefix and suffix, which is at most 3 GSM-7 segments. Reject an empty or too-long message with `400`.

The invitation intentionally **doesn't name a channel**. It has to match the registered wording, and one invitation covers every channel a number is added to (see §8).

A unit test asserts that `invitation` equals the website string exactly. The string is copied into the test rather than imported across repos.

---

## 7. Dashboard auth (`lib/constructs/dashboard-auth.ts`)

```ts
const userPool = new cognito.UserPool(this, 'UserPool', {
  selfSignUpEnabled: false,
  signInAliases: { email: true },
  autoVerify: { email: true },
  featurePlan: cognito.FeaturePlan.ESSENTIALS,
  accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
  mfa: cognito.Mfa.OPTIONAL,                       // see Q4
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

Output the Cognito domain **as a host without `https://`**, `shout-parkernilson.auth.us-west-1.amazoncognito.com`, because Amplify's `loginWith.oauth.domain` expects that form.

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
    allowMethods: [GET, POST, PATCH, DELETE, OPTIONS],
    maxAge: Duration.hours(1),
  },
});
// Default stage throttling: e.g. rateLimit 5, burstLimit 10 (via the CfnStage escape hatch or defaultStage options).
```

With `corsPreflight` set, API Gateway answers `OPTIONS` without invoking the authorizer. Don't add `ANY /{proxy+}` or explicit `OPTIONS` routes, because they would capture preflight.

### Routes

Every route with `{channelId}` returns `404` if the channel doesn't exist. Every route that changes a channel's receivers or sends to them returns `409` if the channel is `archived`.

| Method & path | Lambda | Behavior |
| ------------- | ------ | -------- |
| `GET /channels` | `channels` | Scan the channels table and return all items, including `archived`. The dashboard filters/sorts. |
| `POST /channels` `{ name }` | `channels` | Validate the name (§4). `409` if an `active` channel already has that name (case-insensitive). Put `channelId = randomUUID()`, `status = active`. Return `201` with the item. |
| `PATCH /channels/{channelId}` `{ name }` | `channels` | Rename. The same validation and uniqueness check apply. |
| `DELETE /channels/{channelId}` | `channels` | Archive: `status = archived`, `archivedAt`. Receivers are untouched. |
| `GET /channels/{channelId}/receivers` | `receivers` | `Query` the channel and return each receiver's `name`, `phoneNumber`, `status`, and timestamps, including `removed`. |
| `POST /channels/{channelId}/receivers` `{ phoneNumber, name }` | `receivers` | See **Adding a receiver** below. |
| `DELETE /channels/{channelId}/receivers/{phoneNumber}` | `receivers` | `decodeURIComponent` the path param and normalize it. `404` if the membership is missing. Set `status = removed`, `removedAt`, unless it's `opted_out`, which stays `opted_out` so the opt-out isn't hidden. No SMS. |
| `POST /channels/{channelId}/announcements` `{ message }` | `send-announcement` | Build the final text with `messages.announcement()` and validate its length. Count the channel's `subscribed` receivers, async-invoke `announcement-sender` with `{ channelId, text }`, and return `202 { recipients, preview }`. |

### Adding a receiver

AGENTS.md allows **one invitation text per number, ever**, not one per channel. So adding a number to a channel works like this:

1. Normalize `phoneNumber` to E.164 (accept 10-digit US, `+1…`, common punctuation), else `400`. `name` is required, else `400`.
2. **Refuse with `409` if the number is opted out:** it's on the AWS opt-out list (`DescribeOptedOutNumbers`), or any of its memberships (`byPhone`) is `opted_out`.
3. If a membership in **this** channel is already `invited` or `subscribed` → `409`. A `removed` membership is overwritten by the steps below.
4. Based on the number's **other** memberships:
   - Any of them has `subscribedAt`, meaning the number has replied YES before → put `status = subscribed`, `subscribedAt = now`. **No SMS.** (Q3)
   - Else any of them has `invitedAt`, meaning the number already got its one invitation and hasn't replied → put `status = invited`. **No SMS.** Their eventual YES confirms this membership too.
   - Else → put `status = invited`, `invitedAt = now`, then send `messages.invitation`.
5. Return `{ status, invitationSent }` so the dashboard can tell the admin what happened.

### Lambdas and grants

| Lambda | Grants |
| ------ | ------ |
| `channels` | channels table read/write |
| `receivers` | channels table read, receivers table read/write, `sms-voice:SendTextMessage` on the phone number ARN, `sms-voice:DescribeOptedOutNumbers` on the opt-out list ARN |
| `send-announcement` | channels table read, receivers table read, `lambda:InvokeFunction` on the sender |

**`announcement-sender`** (not an API route): 512 MB, 15 min timeout, `retryAttempts: 0`, `reservedConcurrentExecutions: 1`, so two announcements never interleave and exceed throughput. If a second announcement arrives while one is sending, the async invoke is throttled and Lambda retries it later, up to the 6-hour max event age. The sender queries the channel's `subscribed` receivers and sends one at a time at ~2 msg/s (`await sleep(500)`). An opted-out error calls `markOptedOut`. It logs a summary (channel, sent / opted out / failed). Grants: receivers table read/write and `SendTextMessage`.

A person in two channels gets one text per announcement in each channel. Nothing is de-duplicated across channels.

All API handlers return JSON via `shared/http.ts`. They log the Cognito `sub`/email from `event.requestContext.authorizer.jwt.claims` for an audit trail.

---

## 9. Stack outputs

`CfnOutput`s in `ShoutStack`, which the website copies into `src/lib/config.ts`:

| Output | Value |
| ------ | ----- |
| `UserPoolId` | `userPool.userPoolId` |
| `UserPoolClientId` | `client.userPoolClientId` |
| `CognitoDomain` | `${prefix}.auth.us-west-1.amazoncognito.com` |
| `ApiUrl` | `api.apiEndpoint` (no trailing slash) |
| `ChannelsTableName` | for console/CLI use |
| `ReceiversTableName` | for console/CLI use |

---

## 10. Tests

### `test/shout-stack.test.ts` (template assertions, `aws-cdk-lib/assertions`)

Synthesize `ShoutStack` once with `env: { account: '445044180652', region: 'us-west-1' }`. Then check:

- **No** `AWS::SNS::Topic` or `AWS::SMSVOICE::PhoneNumber` resources (existing ones are never created).
- `AWS::SNS::Subscription` with `Protocol: lambda` and `TopicArn` = the `shout-replies` ARN.
- Channels table: key schema `channelId` HASH. Receivers table: `channelId` HASH + `phoneNumber` RANGE, and GSI `byPhone` with `phoneNumber` HASH + `channelId` RANGE. Both tables: PITR on, deletion protection on, `DeletionPolicy: Retain`, `UpdateReplacePolicy: Retain`.
- User pool: `AdminCreateUserConfig.AllowAdminCreateUserOnly: true`.
- App client: `GenerateSecret: false`, `AllowedOAuthFlows: ['code']`, scopes `openid` + `email`, exact callback/logout URLs.
- **Every** `AWS::ApiGatewayV2::Route` has `AuthorizationType: JWT` (iterate `findResources`, so new routes are covered automatically).
- Authorizer `JwtConfiguration` issuer/audience reference the pool/client.
- API CORS origins, headers, and methods as specified.
- Every IAM statement with `sms-voice:SendTextMessage` has `Resource` = the phone number ARN, and every one with `sms-voice:DescribeOptedOutNumbers` has the opt-out list ARN (no `*`).
- The six outputs exist.

`NodejsFunction` bundling runs esbuild during synth in tests. That's acceptable for this size of project; there is no Docker dependency because esbuild is local.

### `test/lambda/*.test.ts` (pure logic)

- `keywords`: YES variants, every opt-out/opt-in/help keyword, and random text → other.
- `phone`: normalization and rejection cases.
- `messages`: `invitation` equals the website's `confirmationMessage` (literal copy); `announcement()` always contains `STOP` and the `Shout` prefix and fits the length limit; no message constant contains a phone number (contact is email-only).
- Pagination: a mocked two-page `Query`/`Scan` returns items from both pages.
- Handlers: inject the DynamoDB/SMS helpers (or use `aws-sdk-client-mock` if cleaner) and cover:
  - reply handler: YES → every `invited` membership becomes `subscribed`; YES from an unknown number → one `otherReply`, no write; STOP → every non-`removed` membership `opted_out`, no send; other → one reply; opted-out send error → `markOptedOut`.
  - add receiver: the three paths in §8 (fresh number → invitation sent; pending invitation elsewhere → no SMS; YES elsewhere → `subscribed`, no SMS); refusal when opted out (opt-out list or membership) or already in the channel; refusal on an archived channel.
  - channels: duplicate active name → `409`; rename; archive.

No `jest.config.js` change is needed; it already picks up `test/**/*.test.ts`.

---

## 11. Implementation phases

Each phase ends with `npm run build`, `npm run test`, and `npx cdk synth` passing, plus doc updates (a repo rule).

1. **Scaffold.** Rename the stack to `ShoutStack` (`bin/cdk.ts`, `lib/shout-stack.ts`) and add `lib/config.ts`. Add devDependencies: `esbuild`, `@types/aws-lambda`, `@aws-sdk/client-dynamodb`, `@aws-sdk/lib-dynamodb`, `@aws-sdk/client-pinpoint-sms-voice-v2`. Delete the starter test.
2. **Tables + shared libs.** `tables.ts`, `lambda/shared/*`, and their unit tests.
3. **Reply handler.** Construct, handler, SNS subscription, tests.
4. **Cognito.** `dashboard-auth.ts`, outputs, tests.
5. **API + dashboard Lambdas.** `dashboard-api.ts`, the three route Lambdas, the sender worker, tests.
6. **Docs.** In `README.md` / `AGENTS.md`, move components from *planned* to done, rename `lib/cdk-stack.ts` references, document routes, outputs, and the admin-user command, and add `lambda/` to the project structure. Tell the website repo which values to put in its config and that the dashboard needs channel management plus per-channel receiver lists and announcements.

### First deploy checklist (manual, done by Parker)

- `npx cdk bootstrap aws://445044180652/us-west-1` (once).
- `npx cdk deploy`, then copy the outputs into the website's `src/lib/config.ts`.
- Create an admin: `aws cognito-idp admin-create-user --user-pool-id <id> --username <email> --user-attributes Name=email,Value=<email> Name=email_verified,Value=true`.
- In End User Messaging, confirm on the number: two-way SMS → `shout-replies`, HELP keyword response includes the contact email, and the opt-out list is associated (and its name matches `config.optOutListName`). Also confirm that the topic's access policy lets `sms-voice.amazonaws.com` publish; the stack doesn't manage that policy.
- Smoke test with Parker's own phone: create two channels → add to channel A (invitation sent) → add to channel B (no SMS, `invited`) → YES (both `subscribed`) → announce to A → a random text → STOP (both `opted_out`). Check the tables after each step.
- Toll-free registration is still pending. Outbound sends may be blocked or throttled until it's approved.

---

## 12. Open questions (recommendations in bold)

- **Q1. Confirmation reply on YES?** The README only says to add the sender. Toll-free reviewers usually expect an opt-in confirmation message. **Recommend sending one** (`Shout: You're subscribed to local community announcements. Up to 4 msgs/mo. Msg & data rates may apply. Reply HELP for help, STOP to opt out.`), but only if it matches what the toll-free registration submitted. Otherwise skip it.
- **Q2. START/UNSTOP and YES after opt-out.** Carriers handle START/UNSTOP. **Recommend**: on `START`/`UNSTOP`, set every `opted_out` membership of the number to `subscribed` (explicit re-opt-in; record `lastYesAt`). While a number has any `opted_out` membership, ignore YES because sends would be blocked anyway. Verify during the smoke test whether START/UNSTOP messages reach the SNS topic and whether AWS's opt-out list is cleared.
- **Q3. Adding a number that already replied YES to a new channel.** §8 adds it as `subscribed` with no text, because the "single invitation" rule forbids a second invitation and the person has already opted in to Shout messages from this number. **Recommend keeping this**, as long as the toll-free registration describes the opt-in as covering Shout announcements generally rather than one specific list. The alternative is that a number could never join a second channel. Also confirm that re-adding a `removed` membership follows the same rules (recommended: yes).
- **Q4. MFA for admins.** **Recommend `Mfa.REQUIRED` with TOTP.** It's cheap and the dashboard can message a whole channel. Kept `OPTIONAL` above until confirmed.
- **Q5. Unknown numbers texting YES** (no membership on file). With channels there's nowhere to put them. **Recommend** replying with `otherReply` and writing nothing; the admin adds them to a channel from the dashboard. This changes the README's "YES adds the sender to the receivers list" wording.
- **Q6. Announcement history.** Not in the README. **Recommend skipping** for now: CloudWatch logs of the sender are enough. A small `announcements` table can be added later if the dashboard wants history.
- **Q7. Channel name in announcements.** People in several channels can't tell which one a text came from. **Recommend the prefix `Shout (<channel name>): `**. That's why channel names are capped at 40 chars, and the length check applies to the final text.
- **Q8. Message frequency.** The registered wording says "Up to 4 msgs/mo" per number. Several channels can push a number over that. **Recommend** no enforcement for now; the dashboard shows a reminder on the announcement form. If channels make it routine, update the registration and `invitation` wording together.
- **Q9. Opt-out list name.** `config.optOutListName` assumes `Default`. Confirm the actual list associated with the number (`aws pinpoint-sms-voice-v2 describe-phone-numbers`).
