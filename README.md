# shout-cdk

Infrastructure as code (AWS CDK, TypeScript) for the backend of **Shout**, a simple SMS announcement service for the local community. People sign up on a paper or online sign-up sheet or verbally in person, confirm by replying **YES** to a confirmation text, and opt out at any time by replying **STOP**.

The public website (landing page, privacy policy, terms) and the admin dashboard live in the sibling `shout.parkernilson.dev` repo and are hosted on GitHub Pages, not AWS. This repo only defines the AWS side.

> **Status: under development.** The stack in `lib/cdk-stack.ts` is still the CDK starter template. The architecture below is the plan; items marked *existing* were created by hand in the AWS console and are referenced, not created, by this stack.

## Architecture

All resources live in account `445044180652`, region **`us-west-1`**.

| # | Component | Status | Details |
| - | --------- | ------ | ------- |
| 1 | Toll-free number (two-way SMS) | *existing*, registration pending | `+18444933651`<br>`arn:aws:sms-voice:us-west-1:445044180652:phone-number/phone-617c575d8efe4a21aa2a15f5222da64a` |
| 2 | Incoming messages SNS topic | *existing* | `arn:aws:sns:us-west-1:445044180652:shout-replies` — the number's two-way SMS destination |
| 3 | Reply-handler Lambda | planned | Subscribed to the `shout-replies` topic |
| 4 | Channels + receivers DynamoDB tables | planned | Admin-created channels, and who receives each channel's announcements |
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
                                                                 └──► invites / announcements via the toll-free number
```

### Reply handler (incoming SMS)

Triggered by each message published to `shout-replies`:

- **`YES`** → mark the sender subscribed in every channel they've been invited to, and record when they replied YES. A YES from a number that isn't in any channel gets the "anything else" reply (there's no channel to add it to).
- **Anything else** → reply with how to reach Parker Nilson (email: parker.todd.nilson@gmail.com), or to opt out of messages by replying **STOP**.

Notes:

- On US toll-free numbers, **STOP**/**UNSTOP** are handled automatically by the carriers and can't be customized. The handler should not send its "anything else" reply to opt-out keywords, and should mark those numbers as opted out so they're never messaged.
- A **HELP** response is configured on the number in AWS End User Messaging and must include the contact email.
- Keep records of sign-up dates and YES replies; they back the toll-free registration.

### Channels and receivers tables

Admins organize receivers into **channels** (created, renamed, and archived in the dashboard). A phone number can be in several channels.

- **`channels`** table, keyed on a generated `channelId`, holding the channel's name and status (active / archived).
- **`receivers`** table with one item per channel membership: partition key `channelId`, sort key `phoneNumber` (E.164, e.g. `+15551234567`). Each item has the person's name, status (invited → subscribed → opted out, or removed), and timestamps for the invite and YES reply. A global secondary index `byPhone` (partition key `phoneNumber`) finds every channel a number belongs to, which the reply handler needs because incoming texts only carry the phone number.

Only **subscribed** receivers get announcements. Opting out (STOP) applies to the whole number, so it marks every one of the number's memberships opted out.

### Dashboard API

The dashboard is a page on the GitHub Pages site. It signs admins in with Cognito and calls Lambdas through an API Gateway HTTP API to:

- **Manage channels**: create, rename, and archive them.
- **List a channel's receivers** (name, phone number, status), and **manually add or remove** them.
- **Send an announcement** to every subscribed receiver in a channel.
- **Adding a number** to its first channel sends it an invitation text asking the person to reply **YES** if they want to receive announcements. Nothing else is sent until they reply YES. Adding it to more channels never sends a second invitation: it joins as subscribed if it has already replied YES, otherwise as invited (their YES confirms every pending channel).

The invitation wording must match `confirmationMessage` in the website's `src/lib/config.ts` and the AWS toll-free registration. If you change it, update all of them together.

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
- Never message a number that hasn't replied YES, other than the single invitation text.
- Contact info in messages is email-only; never add a personal phone number.
- Before finishing, run `npm run build` and `npm run test`, and check `npx cdk synth` succeeds.
