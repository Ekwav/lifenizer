# Discord bot imports

The native desktop and Android apps import both sides of server-channel conversations from an authorized Discord bot. Real authors become people with `discord:<user ID>` identifiers, allowing merges with email identities and Discord export participants. The own-user-ID field defaults to a Discord identity linked to your vault email when available. For ekwav, use the Discord account ID from the existing export if no default is shown. Mentions alone do not establish authorship or participation. Webhook authors have separate `discord-webhook:` identities.

## Setup

1. Create an application in the [Discord Developer Portal](https://discord.com/developers/applications), add its bot, and enable **Message Content Intent** on the Bot page. Large verified bots may need Discord's approval.
2. Invite the bot with `https://discord.com/oauth2/authorize?client_id=YOUR_APPLICATION_ID&scope=bot&permissions=66560`. This requests **View Channel** (1024) and **Read Message History** (65536); channel overrides must also allow them. No Send Messages permission is requested.
3. In native **Imports → Discord bot: history & live messages**, paste the bot token. Enter comma-separated channel or thread IDs, or a server ID to discover text and announcement channels. Discovery checks read access and skips denied channels. An inaccessible explicit channel produces an actionable error. Enable Discord Developer Mode to copy IDs.
4. Optionally enter your own Discord user ID to identify your side of the conversation, then choose **Connect & import history**.

The token goes directly to Discord over HTTPS. **Remember on this device** saves the token and channel cursors in the OS credential store, scoped to the current vault identity. Imports are normalized locally and encrypted before cursors advance. The Lifenizer server receives only the existing encrypted synchronization envelopes. **Stop & remove bot** closes connections and removes saved bot settings; imported records remain.

## History and live behavior

History uses pages of up to 100 messages, with up to 20 pages per channel per check. Longer histories continue from the oldest saved message every five minutes or with **Check now**. Once backfill completes, polling retrieves new messages missed during disconnection. Channel and message IDs match Discord export imports, avoiding duplicates while adding other authors and replies. Original chat/message links remain available.

The Gateway uses `GUILDS`, `GUILD_MESSAGES`, and `MESSAGE_CONTENT`, heartbeats, session resume and reconnects. Identifying visible message authors requires no member-list intent. Complete creates are coalesced for two seconds in batches of up to 100 per channel; partial edits are completed through REST. Pending bursts are drained between history pages so long backfills do not hold the live queue until completion. Failed or busy batches stay queued for retry. The queue is bounded at 200 distinct messages, with an explicit overflow error. History repairs dropped new messages, but overflowing edits may require history reimport.

**Reimport history & offline edits** resets cursors and rereads existing message IDs. This updates changed text while preserving deduplication and can repair edits missed while closed. Normal new-message polling does not find edits to old messages. Deletions are not mirrored into the vault; a partial edit whose message has already been deleted is skipped so other live messages can continue.

Imports run while the app is open and the vault is unlocked. Locking/logout closes the Gateway and pauses reads. Android may suspend background activity; the next unlocked session resumes history and missed-new-message checks. This importer does not run permanently on the server.

Bots access only channels/threads authorized by the server. They cannot read personal DMs between ekwav and another user; use the Discord account data export for those. Server discovery covers text/announcement channels. Enter individual thread IDs explicitly, including authorized archived/private threads. The bot's own DMs are not imported.

## API references

- [Gateway intents, heartbeats and resume](https://github.com/discord/discord-api-docs/blob/main/developers/events/gateway.mdx)
- [Message authors, content restrictions and pagination](https://github.com/discord/discord-api-docs/blob/main/developers/resources/message.mdx)
- [Channels and thread access](https://github.com/discord/discord-api-docs/blob/main/developers/resources/channel.mdx)
