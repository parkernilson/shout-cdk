# Implementation plan: UC Ward Announcements CDK stack

Status: **draft plan**, not implemented yet (2026-09-30; channels added 2026-10-03; rebranded from Shout and switched to QR code / JOIN keyword opt-in 2026-10-04; fixed channel list, channel-labeled messages, and "message frequency varies" 2026-10-04).

This plan turns the architecture in `README.md` / `AGENTS.md` into CDK code. It also covers the Lambda handlers, tests, and doc updates. The website side (`shout.parkernilson.dev`) is out of scope except where the two repos have to agree (message wording, keywords, callback URLs, CORS origins, stack outputs, API routes).

Guiding rule from both repos: **keep it simple.** One stack, two small tables, a few small Lambdas, no VPC, no custom domains.

### What changed on 2026-10-04

- **Brand:** Shout → **UC Ward Announcements** (the University City Ward, San Diego, of The Church of Jesus Christ of Latter-day Saints). Every outgoing text about a channel starts with `UC Ward (<code>):`, e.g. announcements are `UC Ward (EQ): <announcement>`. Texts not about one channel start with `UC Ward:`.
- **Opt-in:** printed **QR code posters** (with the disclosures) open the phone's messaging app with `JOIN` or `JOIN <channel>` addressed to the toll-free number. Sign-up sheets, the verbal script, the invitation text, the YES confirmation, and dashboard "add receiver" are **gone**. Numbers only enter the system by texting JOIN.
- **Channels are keyword-addressed:** each has a short `code` that people type. The channels are **`ALL`, `EQ`, `RS`, `YM`, `YW`, `PR`, `NR`**. `JOIN` joins the default channel **`EQ`**, `JOIN RS` joins `RS`, `LEAVE RS` leaves `RS`, and STOP leaves every channel. `ALL` is an ordinary channel for announcements that apply to the whole ward: people join it with `JOIN ALL`, and an announcement to `ALL` goes only to its subscribers.
- **Frequency:** disclosures say "message frequency varies" instead of a monthly cap. "Message and data rates may apply" stays (carriers require it).
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
| Opt-in | Inbound keyword only: `JOIN [code]`. The reply handler subscribes the number and sends one confirmation. No outbound message is ever sent to a number that hasn't texted JOIN. |
| Channels | Initial channels `ALL`, `EQ`, `RS`, `YM`, `YW`, `PR`, `NR`, created after the first deploy (§11). Admins can create, rename, and archive channels in the dashboard. Each has an immutable keyword **`code`** (the table key) and a display name. Default channel **`EQ`** (`config.defaultChannel`). A number can be in several channels. Announcements go to one channel at a time. |
| Tables | Two DynamoDB tables, both on-demand, PITR on, deletion protection on, `RemovalPolicy.RETAIN`. **`channels`**: PK `code`. **`receivers`** (one item per channel membership): PK `channelCode`, SK `phoneNumber`, GSI **`byPhone`** (PK `phoneNumber`, SK `channelCode`) for STOP/START, which apply to every channel. |
| Auth | Cognito user pool (`selfSignUpEnabled: false`, Essentials plan, `RETAIN`), Cognito domain with **newer managed login** + default branding, public app client (no secret, code + PKCE, `openid` `email`). |
| API | API Gateway **HTTP API** (`aws-apigatewayv2`) with `HttpUserPoolAuthorizer` as the **default authorizer**, CORS for prod + localhost, low stage throttling. |
| Announcements | API Lambda validates and **async-invokes** a sender Lambda (returns `202`). This avoids the 30 s HTTP API integration timeout and respects the toll-free ~3 msg/s throughput. The sender has `retryAttempts: 0` so a failure never double-sends. |
| Logs | CDK-managed log groups (feature flag already on), 1-month retention. Mask phone numbers in logs (`+1555***4567`). |

---

## 2. Target file layout

```
bin/cdk.ts                         # instantiate UcWardStack (renamed)
lib/
  config.ts                        # ARNs, phone number, URLs, domain prefix, contact email, default channel
  uc-ward-stack.ts                 # composes the constructs below + CfnOutputs
  constructs/
    tables.ts                      # channels + receivers tables (and the byPhone GSI)
    reply-handler.ts               # Lambda + SNS subscription
    dashboard-auth.ts              # user pool, domain, branding, app client
    dashboard-api.ts               # HTTP API, authorizer, routes, dashboard Lambdas
lambda/
  reply-handler.ts
  dashboard/
    channels.ts                    # GET/POST/PATCH/DELETE channels (dispatch on routeKey)
    receivers.ts                   # GET/DELETE receivers within a channel
    send-announcement.ts           # API-facing: validate + async invoke
  announcement-sender.ts           # worker: loops over a channel's subscribed receivers
  shared/
    messages.ts                    # all outgoing SMS text (single source of truth here)
    keywords.ts                    # parse incoming text: JOIN/LEAVE [code], opt-out, opt-in, help, other
    phone.ts                       # E.164 normalize/validate, log masking
    channels.ts                    # DynamoDB access for the channels table, channel code validation
    receivers.ts                   # DynamoDB access for receivers (by channel, by phone via byPhone)
    sms.ts                         # SendTextMessage wrapper + opted-out error detection
    http.ts                        # JSON response helpers for API handlers
test/
  uc-ward-stack.test.ts            # template assertions
  lambda/*.test.ts                 # pure-logic unit tests
docs/internal/implementation-plan.md
```

`lib/cdk-stack.ts` and `test/cdk.test.ts` (starter template) are deleted.

Each dashboard Lambda serves a group of routes and dispatches on `event.routeKey`. That gives three API Lambdas instead of seven.

---

## 3. Configuration (`lib/config.ts`)

Plain constants, no context lookups:

```ts
export const config = {
  phoneNumber: '+18444933651',
  phoneNumberArn: 'arn:aws:sms-voice:us-west-1:445044180652:phone-number/phone-617c575d8efe4a21aa2a15f5222da64a',
  repliesTopicArn: 'arn:aws:sns:us-west-1:445044180652:shout-replies', // existing topic, keeps its old name
  contactEmail: 'parker.todd.nilson@gmail.com',
  defaultChannel: 'EQ',               // joined by a bare JOIN; must match the website's site.defaultChannel
  // Created by hand after the first deploy (§11). Must match the website's site.channels.
  initialChannels: [
    { code: 'ALL', name: 'Whole ward' },   // announcements that apply to everyone
    { code: 'EQ', name: 'Elders Quorum' },
    { code: 'RS', name: 'Relief Society' },
    { code: 'YM', name: 'Young Men' },
    { code: 'YW', name: 'Young Women' },
    { code: 'PR', name: 'Primary' },
    { code: 'NR', name: 'Nursery' },
  ],
  siteOrigin: 'https://shout.parkernilson.dev',
  devOrigin: 'http://localhost:5173',
  cognitoDomainPrefix: 'ucward-parkernilson', // must be unique within us-west-1
};
```

Callback/sign-out URLs are the origins with a trailing `/`. Account/region continue to come from `.env` via `bin/cdk.ts`. `defaultChannel` is passed to the reply handler as `DEFAULT_CHANNEL`.

Guard in `UcWardStack`: if `this.region` is resolved and isn't `us-west-1`, throw. The imported ARNs only exist there.

---

## 4. Tables (`lib/constructs/tables.ts`)

Both tables are `dynamodb.TableV2` with `billing: Billing.onDemand()`, `pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true }`, `deletionProtection: true`, and `removalPolicy: RETAIN`. CloudFormation names them, and the names are passed to Lambdas as `CHANNELS_TABLE` / `RECEIVERS_TABLE`.

**Decide the key schemas before the first deploy.** Changing a key later means CloudFormation replaces the table, and with `RETAIN` that leaves the old table orphaned and the new one empty.

### `channels`

- `partitionKey: { name: 'code', type: STRING }`

| Attribute | Type | Notes |
| --------- | ---- | ----- |
| `code` | S | The keyword people text (`JOIN EQ`). Uppercase letters and digits, 1–10 chars, starts with a letter (`/^[A-Z][A-Z0-9]{0,9}$/`). Stored uppercase; incoming text is uppercased before lookup. **Immutable**, because it's printed on posters and is the key. Must not be a reserved keyword (`JOIN`, `LEAVE`, `HELP`, `INFO`, `START`, `UNSTOP`, and every opt-out keyword in §5). |
| `name` | S | Display name shown in the dashboard, e.g. `Elders Quorum`. 1–40 chars, trimmed. Renaming is a one-item update. |
| `status` | S | `active` \| `archived` |
| `createdAt`, `updatedAt` | S | ISO timestamps |
| `archivedAt` | S? | |

Archiving is a **soft delete**. Receivers in the channel are kept (they're the opt-in records), but the channel can't be joined and can't get announcements. Because the key is the code, an archived code can't be reused for a new channel; that's intentional, since old posters may still point at it. Archiving the default channel is refused (`409`).

The initial channels (`config.initialChannels`, including the default `EQ`) must exist before anyone texts JOIN. They're created by hand in the dashboard after the first deploy (see §11), not by the stack. If a channel is added or archived later, update the website's `site.channels` too.

### `receivers`

One item per **(channel, phone number)** membership. Items are only created by the reply handler, on JOIN.

- `partitionKey: { name: 'channelCode', type: STRING }`, `sortKey: { name: 'phoneNumber', type: STRING }`
- GSI `byPhone`: `partitionKey: phoneNumber`, `sortKey: channelCode`, `projectionType: ALL` (items are tiny)

How each access pattern is served:

| Who | Needs | How |
| --- | ----- | --- |
| Dashboard list, announcement sender | Everyone in a channel | `Query channelCode = :c` on the table |
| Reply handler: JOIN / LEAVE | One membership | `GetItem` / `UpdateItem` by `(channelCode, phoneNumber)` |
| Reply handler: STOP / START | Every channel a number belongs to | `Query phoneNumber = :p` on `byPhone` |
| Dashboard remove | One membership | `UpdateItem` by key |

The GSI is eventually consistent (usually well under a second behind), which is fine for STOP/START. Writes that follow a `byPhone` read go to the table by full key with `ConditionExpression: attribute_exists(phoneNumber)`, so a stale GSI read can't create a stray item.

Item shape (`lambda/shared/receivers.ts`):

| Attribute | Type | Notes |
| --------- | ---- | ----- |
| `channelCode` | S | Partition key |
| `phoneNumber` | S | Sort key. E.164, `+1XXXXXXXXXX` (US only; it's a US toll-free number) |
| `status` | S | `subscribed` \| `left` \| `opted_out` \| `removed` |
| `firstJoinedAt` | S | First JOIN for this channel (`if_not_exists`). The consent record that backs the toll-free registration. |
| `lastJoinedAt` | S | Most recent JOIN |
| `joinMessageId` | S | `inboundMessageId` of the most recent JOIN text, as consent evidence |
| `leftAt` | S? | Last LEAVE |
| `optedOutAt` | S? | Last opt-out keyword seen or opted-out send error |
| `removedAt` | S? | Admin removal |
| `updatedAt` | S | Every write |

Only `status = subscribed` receives announcements. Leaving and removal are **soft** (`left` / `removed`), so the join records are kept for the registration.

**Opt-out is per number, not per channel.** STOP opts a number out of the whole toll-free number at the carrier, so every opt-out path calls one helper, `markOptedOut(phone)`. It queries `byPhone` and sets every `subscribed` membership to `opted_out`. `left` and `removed` memberships are unchanged, so a later START (which restores `opted_out` → `subscribed`) brings back exactly the channels the person was in, not ones they had left.

**Pagination:** `Scan` and `Query` return at most 1 MB per call. Every multi-item read in `shared/channels.ts` and `shared/receivers.ts` (the dashboard lists, `byPhone` lookups, `send-announcement`'s count, `announcement-sender`) must loop on `LastEvaluatedKey`, using `paginateScan` / `paginateQuery` from `@aws-sdk/lib-dynamodb`. Otherwise the dashboard and announcements would silently stop at the first page once the tables grow. Add a unit test that feeds a mocked two-page response and expects both pages.

---

## 5. Reply handler (incoming SMS)

### Infra (`lib/constructs/reply-handler.ts`)

- `NodejsFunction` `lambda/reply-handler.ts`, 256 MB, 10 s timeout.
- `repliesTopic.addSubscription(new subs.LambdaSubscription(fn))` on the imported topic. This creates only an `AWS::SNS::Subscription` and a Lambda permission; the topic itself is untouched.
- Grants: `channels.grantReadData(fn)`, `receivers.grantReadWriteData(fn)` (also covers the `byPhone` index), plus `sms-voice:SendTextMessage` on `config.phoneNumberArn`.
- Env: `CHANNELS_TABLE`, `RECEIVERS_TABLE`, `ORIGINATION_ARN`, `UC_WARD_NUMBER`, `DEFAULT_CHANNEL`.
- Optional: an SQS DLQ on the subscription (`deadLetterQueue`) so failed deliveries aren't lost silently. Cheap, and worth adding.

### Parsing (`lambda/shared/keywords.ts`)

`parse(messageBody)`: trim, uppercase, collapse whitespace, strip surrounding punctuation (`" join eq! "` → `JOIN EQ`). Then:

| Text | Result |
| ---- | ------ |
| `JOIN` | `{ kind: 'join', channel: DEFAULT_CHANNEL }` |
| `JOIN <code>` | `{ kind: 'join', channel: code }` (exactly one word after JOIN; `JOIN ALL` joins the `ALL` channel) |
| `LEAVE` | `{ kind: 'leave', channel: DEFAULT_CHANNEL }` (mirrors bare JOIN; see Q3) |
| `LEAVE <code>` | `{ kind: 'leave', channel: code }` |
| `STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT`, `OPTOUT`, `OPT-OUT`, `REVOKE`, `REMOVE` | `{ kind: 'optOut' }` |
| `START`, `UNSTOP` | `{ kind: 'optIn' }` |
| `HELP`, `INFO` | `{ kind: 'help' }` |
| anything else (including `JOIN` with two or more words after it) | `{ kind: 'other' }` |

### Handler logic (`lambda/reply-handler.ts`)

For each SNS record, `JSON.parse(record.Sns.Message)`, which is End User Messaging's two-way payload: `originationNumber`, `destinationNumber`, `messageBody`, `messageKeyword`, `inboundMessageId`.

1. Ignore messages whose `destinationNumber` isn't `UC_WARD_NUMBER`. This is a defensive check.
2. `parse(messageBody)` and act:
   - **join**
     - `GetItem` the channel. Missing or `archived` → scan the active channel codes and send `messages.unknownChannel(code, activeCodes)`. Don't write.
     - Otherwise upsert the membership `(code, phone)`: `status = subscribed`, `firstJoinedAt = if_not_exists(now)`, `lastJoinedAt = now`, `joinMessageId = inboundMessageId`, `updatedAt = now`. This applies whatever the previous status was (`left`, `removed`, `opted_out`): texting JOIN is a fresh opt-in.
     - Send `messages.joined(code)`. If it fails with the opted-out error (the number is still blocked after a STOP; see Q2), set this membership back to `opted_out` and stop.
     - A JOIN for a channel the number is already subscribed to does the same thing (refreshes `lastJoinedAt`, resends the confirmation). That's idempotent and reassures the person.
   - **leave**
     - Channel missing → send `messages.unknownChannel(code, activeCodes)`.
     - Membership `subscribed` → `status = left`, `leftAt = now`. Any other state (or none) → no write.
     - Either way send `messages.left(code)`. The wording is true whether or not they were in it.
   - **optOut** → `markOptedOut(phone)`. **No reply.** The carrier sends the confirmation.
   - **optIn** (`START`/`UNSTOP`) → set every `opted_out` membership of the number back to `subscribed` (they were subscribed before STOP, and START is an explicit re-opt-in). No reply; the carrier sends its own confirmation. Verify during the smoke test that these messages reach the topic (Q2).
   - **help** → no reply. AWS sends the configured HELP response.
   - **other** → send `messages.otherReply`. Don't change the table. (Most of these will be people replying to an announcement.)
3. Every send goes through `shared/sms.ts`. If it fails with the opted-out conflict (`ConflictException`, reason `DESTINATION_PHONE_NUMBER_OPTED_OUT`), call `markOptedOut` (except in the JOIN case above, which only touches the one membership) and continue. Any other error is thrown so SNS retries it.

Redeliveries are safe: the table updates are idempotent, and at worst a reply is sent twice.

---

## 6. Outgoing messages (`lambda/shared/messages.ts`)

This is the only file that holds SMS wording. Every message about a channel starts with `UC Ward (<code>):` (`prefix(code)`); the rest start with `UC Ward:`. Contact is email-only. No message states a monthly cap; frequency "varies". Every message the handler sends unprompted by a keyword (announcements, `otherReply`) includes STOP wording; the JOIN confirmation carries the full disclosures.

```ts
// MUST match `joinConfirmation` in shout.parkernilson.dev/src/lib/config.ts
// and the AWS toll-free registration. Change all three together.
const prefix = (code: string) => `UC Ward (${code})`;

export const joined = (code: string) =>
  `${prefix(code)}: You're subscribed to ${code} announcements from UC Ward Announcements. Msg frequency varies. Msg & data rates may apply. Reply HELP for help, LEAVE ${code} to leave, STOP to opt out of all.`;

export const left = (code: string) =>
  `${prefix(code)}: You won't get ${code} announcements anymore. Text JOIN ${code} to rejoin, or STOP to stop all UC Ward texts.`;

// activeCodes comes from the channels table, so the list stays current.
export const unknownChannel = (code: string, activeCodes: string[]) =>
  `UC Ward: There's no channel called ${code}. Channels: ${activeCodes.join(', ')}. Text JOIN <channel> to join, or email parker.todd.nilson@gmail.com for help.`;

export const otherReply =
  'UC Ward: This number only sends announcements. Text JOIN <channel> to join, LEAVE <channel> to leave, or STOP to opt out. Questions? Email parker.todd.nilson@gmail.com.';

// Announcements: "UC Ward (<code>): <body>", adding the prefix if missing, and appending
// " Reply STOP to opt out." if the text doesn't already contain STOP. The admin can't produce
// a message without opt-out wording.
export function announcement(code: string, body: string): string;
```

`unknownChannel` echoes at most 10 characters of the code the person typed (truncate longer input) so the reply can't be made arbitrarily long.

Max announcement length: validate in the API, for example 320 characters for the final text including the prefix and suffix, which is at most 3 GSM-7 segments. Reject an empty or too-long message with `400`.

A unit test asserts that `joined('EQ')` equals the website's `joinConfirmation('EQ')` output exactly. The string is copied into the test rather than imported across repos.

---

## 7. Dashboard auth (`lib/constructs/dashboard-auth.ts`)

```ts
const userPool = new cognito.UserPool(this, 'UserPool', {
  selfSignUpEnabled: false,
  signInAliases: { email: true },
  autoVerify: { email: true },
  featurePlan: cognito.FeaturePlan.ESSENTIALS,
  accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
  mfa: cognito.Mfa.OPTIONAL,                       // see Q5
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
    allowMethods: [GET, POST, PATCH, DELETE, OPTIONS],
    maxAge: Duration.hours(1),
  },
});
// Default stage throttling: e.g. rateLimit 5, burstLimit 10 (via the CfnStage escape hatch or defaultStage options).
```

With `corsPreflight` set, API Gateway answers `OPTIONS` without invoking the authorizer. Don't add `ANY /{proxy+}` or explicit `OPTIONS` routes, because they would capture preflight.

### Routes

Path `{code}` is uppercased before lookup. Every route with `{code}` returns `404` if the channel doesn't exist. Sending to an `archived` channel returns `409`.

| Method & path | Lambda | Behavior |
| ------------- | ------ | -------- |
| `GET /channels` | `channels` | Scan the channels table and return all items, including `archived`, each with its subscribed count. The dashboard filters/sorts. |
| `POST /channels` `{ code, name }` | `channels` | Validate the code and name (§4). `409` if the code already exists (active or archived). Put `status = active`. Return `201` with the item. |
| `PATCH /channels/{code}` `{ name }` | `channels` | Rename (display name only; the code never changes). |
| `DELETE /channels/{code}` | `channels` | Archive: `status = archived`, `archivedAt`. `409` for the default channel. Receivers are untouched. |
| `GET /channels/{code}/receivers` | `receivers` | `Query` the channel and return each receiver's `phoneNumber`, `status`, and timestamps, including `left`/`removed`/`opted_out`. |
| `DELETE /channels/{code}/receivers/{phoneNumber}` | `receivers` | `decodeURIComponent` the path param and normalize it. `404` if the membership is missing. Set `status = removed`, `removedAt`, unless it's `opted_out`, which stays `opted_out` so the opt-out isn't hidden. No SMS. The person can rejoin by texting JOIN again. |
| `POST /channels/{code}/announcements` `{ message }` | `send-announcement` | Build the final text with `messages.announcement(code, message)` and validate its length. Count the channel's `subscribed` receivers, async-invoke `announcement-sender` with `{ channelCode, text }`, and return `202 { recipients, preview }`. |

There is **no "add receiver" route**: numbers only join by texting JOIN, which is the only opt-in the posters and registration describe.

### Lambdas and grants

| Lambda | Grants |
| ------ | ------ |
| `channels` | channels table read/write, receivers table read (subscribed counts) |
| `receivers` | channels table read, receivers table read/write |
| `send-announcement` | channels table read, receivers table read, `lambda:InvokeFunction` on the sender |

No dashboard Lambda can send SMS directly.

**`announcement-sender`** (not an API route): 512 MB, 15 min timeout, `retryAttempts: 0`, `reservedConcurrentExecutions: 1`, so two announcements never interleave and exceed throughput. If a second announcement arrives while one is sending, the async invoke is throttled and Lambda retries it later, up to the 6-hour max event age. The sender queries the channel's `subscribed` receivers and sends one at a time at ~2 msg/s (`await sleep(500)`). An opted-out error calls `markOptedOut`. It logs a summary (channel, sent / opted out / failed). Grants: receivers table read/write and `SendTextMessage`.

A person in two channels gets one text per announcement in each channel. Nothing is de-duplicated across channels.

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
| `ChannelsTableName` | for console/CLI use |
| `ReceiversTableName` | for console/CLI use |

---

## 10. Tests

### `test/uc-ward-stack.test.ts` (template assertions, `aws-cdk-lib/assertions`)

Synthesize `UcWardStack` once with `env: { account: '445044180652', region: 'us-west-1' }`. Then check:

- **No** `AWS::SNS::Topic` or `AWS::SMSVOICE::PhoneNumber` resources (existing ones are never created).
- `AWS::SNS::Subscription` with `Protocol: lambda` and `TopicArn` = the `shout-replies` ARN.
- Channels table: key schema `code` HASH. Receivers table: `channelCode` HASH + `phoneNumber` RANGE, and GSI `byPhone` with `phoneNumber` HASH + `channelCode` RANGE. Both tables: PITR on, deletion protection on, `DeletionPolicy: Retain`, `UpdateReplacePolicy: Retain`.
- User pool: `AdminCreateUserConfig.AllowAdminCreateUserOnly: true`.
- App client: `GenerateSecret: false`, `AllowedOAuthFlows: ['code']`, scopes `openid` + `email`, exact callback/logout URLs.
- **Every** `AWS::ApiGatewayV2::Route` has `AuthorizationType: JWT` (iterate `findResources`, so new routes are covered automatically), and there is no `POST /channels/{code}/receivers` route.
- Authorizer `JwtConfiguration` issuer/audience reference the pool/client.
- API CORS origins, headers, and methods as specified.
- Every IAM statement with `sms-voice:SendTextMessage` has `Resource` = the phone number ARN (no `*`), and only the reply handler's and sender's roles have it.
- The reply handler's `DEFAULT_CHANNEL` env var is `EQ`.
- The six outputs exist.

`NodejsFunction` bundling runs esbuild during synth in tests. That's acceptable for this size of project; there is no Docker dependency because esbuild is local.

### `test/lambda/*.test.ts` (pure logic)

- `keywords`: `JOIN` → default channel; `join rs!`, `JOIN  yw`, `JOIN ALL` → that code; bare `LEAVE` → default; `LEAVE RS`; `JOIN A B` → other; every opt-out/opt-in/help keyword; random text → other.
- Channel code validation: accepts every code in `initialChannels` and e.g. `CH1`; rejects empty, lowercase-after-normalizing edge cases, 11+ chars, leading digit, punctuation, and reserved keywords.
- `phone`: normalization and rejection cases.
- `messages`: `joined('EQ')` equals the website's `joinConfirmation('EQ')` (literal copy); `joined`, `left`, and `announcement()` start with `UC Ward (<code>): `; the others start with `UC Ward:`; `announcement()` always contains `STOP` and fits the length limit with the longest code; no message contains `msgs/mo` (frequency varies); no message contains a phone number (contact is email-only).
- Pagination: a mocked two-page `Query`/`Scan` returns items from both pages.
- Handlers: inject the DynamoDB/SMS helpers (or use `aws-sdk-client-mock` if cleaner) and cover:
  - reply handler: `JOIN` → `EQ` membership `subscribed` + `joined('EQ')`; `JOIN RS` → `RS`; JOIN for an unknown or archived channel → `unknownChannel` listing the active codes, no write; JOIN after LEAVE/removal → `subscribed` again with `firstJoinedAt` unchanged; `LEAVE RS` → `left` + `left('RS')`; LEAVE when not a member → reply, no write; STOP → every `subscribed` membership `opted_out` and `left` ones unchanged, no send; START → `opted_out` memberships back to `subscribed` (a `left` one stays `left`), no send; other → one `otherReply`; opted-out send error on JOIN → that membership `opted_out`.
  - receivers: remove → `removed`; remove of an `opted_out` membership stays `opted_out`.
  - channels: invalid/reserved/duplicate code → `400`/`409`; rename; archive; archiving the default channel → `409`.

No `jest.config.js` change is needed; it already picks up `test/**/*.test.ts`.

---

## 11. Implementation phases

Each phase ends with `npm run build`, `npm run test`, and `npx cdk synth` passing, plus doc updates (a repo rule).

1. **Scaffold.** Rename the stack to `UcWardStack` (`bin/cdk.ts`, `lib/uc-ward-stack.ts`) and add `lib/config.ts`. Add devDependencies: `esbuild`, `@types/aws-lambda`, `@aws-sdk/client-dynamodb`, `@aws-sdk/lib-dynamodb`, `@aws-sdk/client-pinpoint-sms-voice-v2`. Delete the starter test.
2. **Tables + shared libs.** `tables.ts`, `lambda/shared/*`, and their unit tests.
3. **Reply handler.** Construct, handler, SNS subscription, tests.
4. **Cognito.** `dashboard-auth.ts`, outputs, tests.
5. **API + dashboard Lambdas.** `dashboard-api.ts`, the three route Lambdas, the sender worker, tests.
6. **Docs.** In `README.md` / `AGENTS.md`, move components from *planned* to done, rename `lib/cdk-stack.ts` references, document routes, outputs, and the admin-user command, and add `lambda/` to the project structure. Tell the website repo which values to put in its config and that the dashboard needs channel management (code + name) plus per-channel receiver lists and announcements, and no add-receiver form.

### First deploy checklist (manual, done by Parker)

- `npx cdk bootstrap aws://445044180652/us-west-1` (once).
- `npx cdk deploy`, then copy the outputs into the website's `src/lib/config.ts`.
- Create an admin: `aws cognito-idp admin-create-user --user-pool-id <id> --username <email> --user-attributes Name=email,Value=<email> Name=email_verified,Value=true`.
- In the dashboard (or the console), **create the seven channels in `config.initialChannels`** with their display names (`ALL` Whole ward, `EQ` Elders Quorum, `RS` Relief Society, `YM` Young Men, `YW` Young Women, `PR` Primary, `NR` Nursery).
- In End User Messaging, confirm on the number: two-way SMS → `shout-replies`; the HELP keyword response includes the contact email and the JOIN/LEAVE/STOP keywords (e.g. `UC Ward Announcements: text JOIN <channel> to join, LEAVE <channel> to leave, STOP to opt out. Help: parker.todd.nilson@gmail.com. Msg & data rates may apply.`); no custom keyword is configured for `JOIN` or `LEAVE` (they must reach the handler, not get an AWS auto-response). Also confirm that the topic's access policy lets `sms-voice.amazonaws.com` publish; the stack doesn't manage that policy.
- Print posters with a QR code for `SMSTO:+18444933651:JOIN` (or e.g. `SMSTO:+18444933651:JOIN RS` for other channels) next to the website's `posterDisclosure()` text. Test-scan each with both an iPhone and an Android phone before printing in bulk.
- Update the toll-free registration's opt-in workflow: QR code poster → user-initiated JOIN text → confirmation. Attach a photo or PDF of the poster and link the prerendered site.
- Smoke test with Parker's own phone: create the seven channels → scan the EQ poster and send JOIN (`EQ` subscribed, confirmation reads `UC Ward (EQ): ...`) → `JOIN RS` → `JOIN NOPE` (unknown channel reply listing the channels) → announce to `EQ` (message reads `UC Ward (EQ): ...`) → `LEAVE RS` (`left`) → a random text (`otherReply`) → STOP (`EQ` `opted_out`, `RS` stays `left`) → START (`EQ` back to `subscribed`, `RS` still `left`) → `JOIN RS`. Check the tables after each step.
- Toll-free registration is still pending. Outbound sends may be blocked or throttled until it's approved.

---

## 12. Open questions (recommendations in bold)

- **Q1. What `ALL` means.** *Resolved 2026-10-04:* `ALL` is an ordinary channel for announcements that apply to the whole ward. `JOIN ALL` joins only that channel, and announcements to it reach only its subscribers.
- **Q2. JOIN after STOP.** On toll-free numbers, STOP blocks the number at the carrier, and only START/UNSTOP lifts it, so a JOIN from a stopped number reaches the handler but the confirmation fails as opted out. The plan handles that by leaving the membership `opted_out`. **Recommend** the posters and site keep telling people to reply START to opt back in (already on the site), and verifying in the smoke test (a) whether START/UNSTOP reach the SNS topic and (b) whether AWS's opt-out list is cleared by START. If START doesn't reach the topic, a later JOIN can't recover the number automatically; consider `DeleteOptedOutNumber` on JOIN only if AWS documents that as allowed for user-initiated re-opt-in.
- **Q3. Bare LEAVE.** Mirrors bare JOIN and leaves the default channel `EQ`. The alternative is replying with instructions. **Recommend mirroring** (it's what the site and terms say), since STOP is always the advertised "stop everything".
- **Q4. Message frequency.** The advertised wording is now "message frequency varies", with no monthly cap. **Recommend** using the same wording in the toll-free registration's message-volume and sample-message fields, and no enforcement in code.
- **Q5. MFA for admins.** **Recommend `Mfa.REQUIRED` with TOTP.** It's cheap and the dashboard can message a whole channel. Kept `OPTIONAL` above until confirmed.
- **Q6. Announcement history.** **Recommend skipping** for now: CloudWatch logs of the sender are enough. A small `announcements` table can be added later if the dashboard wants history.
- **Q7. Domain and topic names.** The site is still at `shout.parkernilson.dev` and the topic is `shout-replies`. **Recommend** leaving the topic name (it's never user-visible). If the domain moves before the toll-free registration is resubmitted, change `config.siteOrigin`, the Cognito callback/logout URLs, CORS origins, and the website's `site.url`/`static/CNAME` together, and reprint the posters.
