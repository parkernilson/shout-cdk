# shout-cdk

Infrastructure as code (AWS CDK, TypeScript) for the backend of **UC Ward Announcements**, a simple SMS announcement service for the University City Ward (San Diego) of The Church of Jesus Christ of Latter-day Saints. People opt in by scanning a QR code on a printed poster, which opens their messaging app with **JOIN** (default channel **EQ**) or **JOIN <channel>** texted to the toll-free number. **LEAVE <channel>** leaves a channel, and **STOP** opts out of every channel. The channels are `ALL` (whole ward: announcements that apply to everyone), `EQ` (Elders Quorum), `RS` (Relief Society), `YM` (Young Men), `YW` (Young Women), `PR` (Primary), and `NR` (Nursery). Outgoing texts about a channel start with `UC Ward (<channel>):`; others start with `UC Ward:`.

The repo, the website domain, and the existing SNS topic still use the old "Shout" name.

The public website (landing page, privacy policy, terms) and the admin dashboard live in the sibling `shout.parkernilson.dev` repo and are hosted on GitHub Pages, not AWS. This repo only defines the AWS side.

> **Status: under development.** The stack in `lib/cdk-stack.ts` is still the CDK starter template. The architecture below is the plan; items marked *existing* were created by hand in the AWS console and are referenced, not created, by this stack.

## Architecture

All resources live in account `445044180652`, region **`us-west-1`**.

| # | Component | Status | Details |
| - | --------- | ------ | ------- |
| 1 | Toll-free number (two-way SMS) | *existing*, registration pending | `+18444933651`<br>`arn:aws:sms-voice:us-west-1:445044180652:phone-number/phone-617c575d8efe4a21aa2a15f5222da64a` |
| 2 | Incoming messages SNS topic | *existing* | `arn:aws:sns:us-west-1:445044180652:shout-replies` — the number's two-way SMS destination (keeps its pre-rebrand name) |
| 3 | Reply-handler Lambda | planned | Subscribed to the `shout-replies` topic |
| 4 | Channels + receivers DynamoDB tables | planned | Admin-created channels (keyed by keyword code, e.g. `EQ`), and who has joined each one |
| 5 | Dashboard API + Cognito | planned | Cognito user pool (managed login) + API Gateway HTTP API with a JWT authorizer, in front of the dashboard Lambdas |

```
Incoming replies
  Phone ──► Toll-free number ──► SNS: shout-replies ──► Reply-handler Lambda ──► DynamoDB: receivers
                                                                 │
                                                                 └──► auto-reply SMS via the toll-free number

Dashboard
  Browser (GitHub Pages) ──► Cognito managed login (PKCE) ──► access token
  Browser ──access token──► HTTP API (JWT authorizer) ──► Dashboard Lambdas ──► DynamoDB: channels, receivers
                                                                 │
                                                                 └──► announcements via the toll-free number
```

### Reply handler (incoming SMS)

Triggered by each message published to `shout-replies`. This is the only way a number gets into the system:

- **`JOIN`** → subscribe the sender to the default channel **`EQ`** and reply with the join confirmation. **`JOIN <code>`** does the same for that channel. An unknown or archived code gets an "unknown channel" reply and nothing is written.
- **`LEAVE <code>`** → unsubscribe the sender from that channel and confirm. A bare **`LEAVE`** leaves `EQ`.
- **Anything else** → reply with the JOIN/LEAVE/STOP keywords and how to reach Parker Nilson (email: parker.todd.nilson@gmail.com).

Notes:

- On US toll-free numbers, **STOP** and **START**/**UNSTOP** are handled automatically by the carriers and can't be customized. The handler doesn't reply to them. STOP marks the number opted out in every channel it's subscribed to; START restores those channels.
- A **HELP** response is configured on the number in AWS End User Messaging and must include the contact email and the JOIN/LEAVE/STOP keywords.
- Keep records of when each number joined; they back the toll-free registration.

### Channels and receivers tables

Admins create, rename, and archive **channels** in the dashboard. Each channel has a short, immutable keyword **code** (uppercase letters/digits, e.g. `EQ`, `RS`) that people text after JOIN/LEAVE and that's printed on its posters, plus a display name. The initial channels `ALL`, `EQ`, `RS`, `YM`, `YW`, `PR`, `NR` (default `EQ`) are created by hand after the first deploy and must match `site.channels` on the website. A phone number can be in several channels.

- **`channels`** table, keyed on `code`, holding the display name and status (active / archived).
- **`receivers`** table with one item per channel membership: partition key `channelCode`, sort key `phoneNumber` (E.164, e.g. `+15551234567`). Each item has a status (subscribed / left / opted out / removed) and timestamps for joining, leaving, opting out, and removal. A global secondary index `byPhone` (partition key `phoneNumber`) finds every channel a number belongs to, which STOP/START need. No names are stored; a text only carries the phone number.

Only **subscribed** receivers get announcements. Opting out (STOP) applies to the whole number, so it marks every one of the number's subscribed memberships opted out.

### Dashboard API

The dashboard is a page on the GitHub Pages site. It signs admins in with Cognito and calls Lambdas through an API Gateway HTTP API to:

- **Manage channels**: create (code + name), rename, and archive them.
- **List a channel's receivers** (phone number, status, join date) and **remove** them.
- **Send an announcement** to every subscribed receiver in a channel. It goes out as `UC Ward (<channel>): <announcement>`, with STOP wording appended if missing.

Admins **can't add numbers**: people only join by texting JOIN, which is the opt-in the posters and the toll-free registration describe.

The join confirmation wording must match `joinConfirmation` in the website's `src/lib/config.ts` and the AWS toll-free registration. If you change it, update all of them together.

### Dashboard auth

- **Cognito user pool** with **self-sign-up turned off**. Admin users are created by hand (console or `aws cognito-idp admin-create-user`); the stack doesn't create any users.
- **Managed login** (Cognito's hosted sign-in pages) on a Cognito domain for the pool.
- **App client** with **no client secret**, using the **authorization code flow with PKCE** (scopes `openid`, `email`).
  - Callback and sign-out URLs: `https://shout.parkernilson.dev/` and `http://localhost:5173/` (for development).
- **API Gateway HTTP API** in front of the dashboard Lambdas, with a **JWT authorizer** pointed at the user pool (issuer `https://cognito-idp.us-west-1.amazonaws.com/<userPoolId>`, audience = the app client ID). Every dashboard route requires the authorizer.
- **CORS** on the HTTP API allows origin `https://shout.parkernilson.dev` with the `Authorization` and `Content-Type` headers. Local development against the deployed API also needs `http://localhost:5173` in the allowed origins.
- The stack should output the user pool ID, app client ID, Cognito domain, and API URL (plus the table names, for console/CLI use). The website stores them in its config. They're public identifiers, not secrets.

On the frontend, the website uses the `aws-amplify` package: `aws-amplify/auth` handles the managed-login redirect and PKCE exchange, and `aws-amplify/api` calls the HTTP API. A `headers` function passed to `Amplify.configure` adds the Cognito access token as the `Authorization` header on every call. See "Admin dashboard" in the website's `README.md`.

## Setup

Requires Node.js and AWS credentials for the account above.

```sh
npm install
cp .env.example .env   # then set AWS_PROFILE
```

`.env.example` already has `CDK_ACCOUNT=445044180652` and `CDK_REGION=us-west-1`; keep those, since the existing number and topic live there. `bin/cdk.ts` loads `.env` and falls back to the active AWS profile's account/region.

## Commands

```sh
npm run build     # type-check
npm run watch     # type-check on change
npm run test      # jest unit tests
npx cdk synth     # emit the CloudFormation template
npx cdk diff      # compare against the deployed stack
npx cdk deploy    # deploy the stack
```

## Project structure

- `docs/internal/implementation-plan.md` — the detailed implementation plan (draft)
- `bin/cdk.ts` — CDK app entry point; loads `.env` and instantiates the stack
- `lib/cdk-stack.ts` — the stack definition
- `test/` — jest tests (use `aws-cdk-lib/assertions` against the synthesized template)
- `.env.example` — template for the gitignored `.env` (AWS profile, account, region)
- `cdk.json` — CDK toolkit config and feature flags
- `justfile` — helper recipes for running Claude Code in Docker
- `AGENTS.md` — guidance for AI agents

## Contributing (humans and AI agents)

See also `AGENTS.md`.

- **Keep docs current.** Whenever you make a change, update `README.md`, `AGENTS.md`, and any other relevant documentation in the same change so they reflect the new state of the project (e.g. move a component from *planned* to done, record new resource names/ARNs, document new commands).
- Keep things simple; this is a small project.
- Reference the existing phone number and SNS topic by ARN; don't let the stack create or delete them.
- Keep Cognito self-sign-up off and every dashboard API route behind the JWT authorizer.
- Never remove or obscure the STOP opt-out instructions in outgoing messages; clear opt-in/opt-out wording is required for SMS compliance.
- Never message a number that hasn't texted JOIN. There's no admin "add number" path.
- Contact info in messages is email-only; never add a personal phone number.
- Before finishing, run `npm run build` and `npm run test`, and check `npx cdk synth` succeeds.
