# AGENTS.md

Guidance for AI agents working in this repo.

## Project

Shout is a simple SMS announcement service for the local community: users opt in via a paper or online sign-up sheet or verbally in person, confirm by replying YES to a confirmation text (two-way SMS on AWS), and opt out by texting STOP. This repo (`shout-cdk`) is the AWS CDK (TypeScript) infrastructure for Shout's backend. It is under development: `lib/cdk-stack.ts` is still the starter template. The website and admin dashboard live in the sibling `shout.parkernilson.dev` repo (SvelteKit, GitHub Pages).

Everything deploys to account `445044180652`, region `us-west-1` (set in the gitignored `.env`; see `.env.example`). Planned backend:

- **Existing, referenced by ARN (never created or deleted by the stack):** the toll-free number `+18444933651` (`arn:aws:sms-voice:us-west-1:445044180652:phone-number/phone-617c575d8efe4a21aa2a15f5222da64a`, registration pending) and its two-way SMS destination, SNS topic `arn:aws:sns:us-west-1:445044180652:shout-replies`.
- **Reply-handler Lambda** subscribed to `shout-replies`: `YES` subscribes the sender in every channel they've been invited to (a YES from a number in no channel gets the "anything else" reply); anything else gets a reply with the contact email (parker.todd.nilson@gmail.com) and how to opt out with STOP. Opt-out keywords (STOP etc.) are handled by carriers; don't auto-reply to them, and mark those numbers opted out in every channel.
- **DynamoDB tables:** `channels` (admin-created, keyed on generated `channelId`) and `receivers` (one item per channel membership: PK `channelId`, SK E.164 `phoneNumber`, GSI `byPhone` on `phoneNumber`), with the person's name, status (invited / subscribed / opted out / removed) and timestamps. A number can be in several channels.
- **Dashboard auth:** Cognito user pool with self-sign-up off (admins created by hand), managed login, app client with no secret using authorization code + PKCE, callback/sign-out URLs `https://shout.parkernilson.dev/` and `http://localhost:5173/`.
- **Dashboard API:** API Gateway HTTP API with a JWT authorizer on the user pool (audience = app client ID) in front of Lambdas that manage channels, list a channel's receivers, add/remove receivers (adding a number sends the invitation text only if it has never been invited), and send announcements to a channel. CORS allows `https://shout.parkernilson.dev` (plus `http://localhost:5173` for development).
- Stack outputs: user pool ID, app client ID, Cognito domain, API URL — copied into the website's config.

See `README.md` for details, commands, and structure, and `docs/internal/implementation-plan.md` for the detailed plan.

## Rules

- **Keep docs current.** Whenever you make a change, update `AGENTS.md`, `README.md`, and any other relevant documentation in the same change so they reflect the new state of the project (including the website repo's docs when the API, auth setup, or message wording changes).
- Keep things simple; this is a small project.
- Before finishing, run `npm run build` and `npm run test`, and check `npx cdk synth` succeeds.
- Never remove or obscure the STOP opt-out instructions in outgoing messages; clear opt-in/opt-out wording is required for SMS compliance.
- Never message a number that hasn't replied YES, other than the single invitation text. The invitation wording must match `confirmationMessage` in the website's `src/lib/config.ts` and the AWS toll-free registration.
- Contact info in messages is email-only; never add a personal phone number.
- Keep Cognito self-sign-up off and every dashboard API route behind the JWT authorizer. Don't add a client secret to the app client (the dashboard is a public browser client).
