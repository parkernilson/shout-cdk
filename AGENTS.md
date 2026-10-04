# AGENTS.md

Guidance for AI agents working in this repo.

## Project

UC Ward Announcements is a simple SMS announcement service for the University City Ward (San Diego) of The Church of Jesus Christ of Latter-day Saints: people opt in by scanning a QR code poster that opens their messaging app with `JOIN` (default channel `EQ`) or `JOIN <channel>` texted to the toll-free number (two-way SMS on AWS), leave a channel with `LEAVE <channel>`, and opt out of everything with STOP. The channels are `ALL` (whole ward), `EQ` (Elders Quorum), `RS` (Relief Society), `YM` (Young Men), `YW` (Young Women), `PR` (Primary), `NR` (Nursery); `ALL` is an ordinary channel people join like any other. Texts about a channel start with `UC Ward (<channel>):`, others with `UC Ward:`. This repo (`shout-cdk`, named before the rebrand from "Shout") is the AWS CDK (TypeScript) infrastructure for the backend. It is under development: `lib/cdk-stack.ts` is still the starter template. The website and admin dashboard live in the sibling `shout.parkernilson.dev` repo (SvelteKit, GitHub Pages).

Everything deploys to account `445044180652`, region `us-west-1` (set in the gitignored `.env`; see `.env.example`). Planned backend:

- **Existing, referenced by ARN (never created or deleted by the stack):** the toll-free number `+18444933651` (`arn:aws:sms-voice:us-west-1:445044180652:phone-number/phone-617c575d8efe4a21aa2a15f5222da64a`, registration pending) and its two-way SMS destination, SNS topic `arn:aws:sns:us-west-1:445044180652:shout-replies`.
- **Reply-handler Lambda** subscribed to `shout-replies` (the topic keeps its old name): `JOIN [code]` subscribes the sender to that channel (default `EQ`) and sends the join confirmation (unknown/archived code → "unknown channel" reply); `LEAVE [code]` leaves it; anything else gets a reply with the keywords and the contact email (parker.todd.nilson@gmail.com). STOP/START are handled by carriers; don't auto-reply to them. STOP marks the number's subscribed memberships opted out; START restores them.
- **DynamoDB tables:** `channels` (admin-created, keyed on the immutable keyword `code`, e.g. `EQ`, plus display name and status) and `receivers` (one item per channel membership: PK `channelCode`, SK E.164 `phoneNumber`, GSI `byPhone` on `phoneNumber`), with status (subscribed / left / opted out / removed) and timestamps. No names. A number can be in several channels.
- **Dashboard auth:** Cognito user pool with self-sign-up off (admins created by hand), managed login, app client with no secret using authorization code + PKCE, callback/sign-out URLs `https://shout.parkernilson.dev/` and `http://localhost:5173/`.
- **Dashboard API:** API Gateway HTTP API with a JWT authorizer on the user pool (audience = app client ID) in front of Lambdas that manage channels, list and remove a channel's receivers (there is no add: numbers only join by texting JOIN), and send announcements (`UC Ward (<channel>): <announcement>`) to a channel. CORS allows `https://shout.parkernilson.dev` (plus `http://localhost:5173` for development).
- Stack outputs: user pool ID, app client ID, Cognito domain, API URL — copied into the website's config.

See `README.md` for details, commands, and structure, and `docs/internal/implementation-plan.md` for the detailed plan.

## Rules

- **Keep docs current.** Whenever you make a change, update `AGENTS.md`, `README.md`, and any other relevant documentation in the same change so they reflect the new state of the project (including the website repo's docs when the API, auth setup, or message wording changes).
- Keep things simple; this is a small project.
- Before finishing, run `npm run build` and `npm run test`, and check `npx cdk synth` succeeds.
- Never remove or obscure the STOP opt-out instructions in outgoing messages; clear opt-in/opt-out wording is required for SMS compliance.
- Never message a number that hasn't texted JOIN; don't add an admin path that adds numbers. The join confirmation wording must match `joinConfirmation` in the website's `src/lib/config.ts` and the AWS toll-free registration.
- Every outgoing text about a channel starts with `UC Ward (<channel>):`; the rest start with `UC Ward:`. Disclosures say "message frequency varies" (no monthly cap) and keep "message and data rates may apply".
- Contact info in messages is email-only; never add a personal phone number.
- Keep Cognito self-sign-up off and every dashboard API route behind the JWT authorizer. Don't add a client secret to the app client (the dashboard is a public browser client).
