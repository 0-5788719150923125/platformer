"""arcbot Discord Bot - Standalone container process.

Connects to Discord via discord.py, responds to mentions/replies/DMs using
the shared Bedrock Converse backend (ai_backend.py). Adapted from the praxis
Discord integration pattern but replaces local model inference with Bedrock
API calls and adds KB retrieval, deny list filtering, and response rate sampling.

Config is loaded from environment variables (injected by Docker Compose).
"""

import asyncio
import contextlib
import json
import logging
import os
import random

import discord


@contextlib.asynccontextmanager
async def _noop_context():
    """No-op async context manager — replaces typing indicator for ambient messages."""
    yield

import io
import time

from ai_backend import (
    bedrock_converse,
    compose_system_prompt,
    execute_tool,
    generate_image,
    merge_text_into_content,
    load_env,
    load_system_prompt,
    retrieve_kb_context,
    IMAGE_ORIENTATIONS,
    NO_RESPONSE_SENTINEL,
    TOOL_DEFINITIONS,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("arcbot.discord")

# ── Environment ──────────────────────────────────────────────────────────────

ENV = load_env()
SYSTEM_PROMPT = load_system_prompt()
EFFECTIVE_SYSTEM_PROMPT = compose_system_prompt(SYSTEM_PROMPT, ENV["deny_list"])

DISCORD_TOKEN = os.environ["DISCORD_TOKEN"]
BOT_NAME = os.environ.get("BOT_NAME", "arcbot")
DISCORD_NICKNAME = os.environ.get("DISCORD_NICKNAME", "")
DISCORD_HISTORY_LIMIT = int(os.environ.get("DISCORD_HISTORY_LIMIT", "20"))
DISCORD_TOOL_CHANNELS = json.loads(os.environ.get("DISCORD_TOOL_CHANNELS", "[]"))

# ── Vision support ───────────────────────────────────────────────────────────

# Bedrock Converse caps: 20 images per request, 5 MB per image.
MAX_IMAGES_PER_CALL = 20
MAX_IMAGE_BYTES = 5_000_000

# Filename extensions we treat as "probably an image" during the cheap pre-scan.
# Discord's content_type is unreliable (sometimes None, sometimes wrong - e.g.
# claims image/webp for actual PNG bytes), so this is only an advisory filter.
# The actual Converse format string is determined by sniffing magic bytes after
# download, in _sniff_image_format.
IMAGE_EXTENSIONS = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp"})


def _looks_like_image(attachment):
    """Loose pre-scan filter: is this attachment plausibly an image?

    Trusts neither Discord's content_type nor the filename alone, but accepts
    either as a signal. Final format is always determined by sniffing bytes.
    """
    content_type = (attachment.content_type or "").split(";")[0].strip().lower()
    if content_type.startswith("image/"):
        return True
    filename = (attachment.filename or "").lower()
    return any(filename.endswith(ext) for ext in IMAGE_EXTENSIONS)


def _sniff_image_format(data):
    """Detect a Bedrock-compatible image format from raw bytes via magic numbers.

    Returns one of 'png', 'jpeg', 'gif', 'webp', or None if unrecognized.
    Bedrock validates declared format against actual bytes, so this is the
    only authoritative source of truth - filename and content_type can lie.
    """
    if not data:
        return None
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return "gif"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None

# ── Cross-channel messaging tool ─────────────────────────────────────────────

SEND_CHANNEL_MESSAGE_TOOL = {
    "toolSpec": {
        "name": "send_channel_message",
        "description": (
            "Send a message to another Discord channel. Use this to post questions, "
            "updates, or information in a different channel from the one you're "
            "currently responding in. Only whitelisted channels are available."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "channel_name": {
                        "type": "string",
                        "description": "Name of the target Discord channel.",
                    },
                    "message": {
                        "type": "string",
                        "description": "The message text to send.",
                    },
                },
                "required": ["channel_name", "message"],
            }
        },
    }
}

READ_CHANNEL_MESSAGES_TOOL = {
    "toolSpec": {
        "name": "read_channel_messages",
        "description": (
            "Read recent messages from a Discord channel. Use this to understand "
            "what's being discussed before sending a message. Only whitelisted "
            "channels are available."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "channel_name": {
                        "type": "string",
                        "description": "Name of the Discord channel to read.",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Number of recent messages to fetch (default 20, max 50).",
                    },
                },
                "required": ["channel_name"],
            }
        },
    }
}


GENERATE_IMAGE_TOOL = {
    "toolSpec": {
        "name": "generate_image",
        "description": (
            "Generate an image from a text prompt and post it to a Discord "
            "channel as an attachment - by default the current channel, or a "
            "whitelisted channel named via channel_name. Use this when a user "
            "asks you to draw, create, render, imagine, or visualize something. "
            "The generated image is also returned to you so you can see what was "
            "produced and describe or caption it in your reply. Write prompts as "
            "rich visual descriptions (subject, style, lighting, composition) "
            "rather than conversational requests."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": (
                            "Visual description of the image to generate "
                            "(max ~1000 chars)."
                        ),
                    },
                    "negative_prompt": {
                        "type": "string",
                        "description": (
                            "Optional: things to avoid in the image, as a plain "
                            "description (e.g. 'text, watermarks, blurry')."
                        ),
                    },
                    "orientation": {
                        "type": "string",
                        "enum": sorted(IMAGE_ORIENTATIONS),
                        "description": "Image shape (default: square).",
                    },
                    "channel_name": {
                        "type": "string",
                        "description": (
                            "Optional: name of a whitelisted Discord channel to "
                            "post the image to. Omit to post to the current "
                            "channel/DM."
                        ),
                    },
                },
                "required": ["prompt"],
            }
        },
    }
}


def _make_tool_executor(client, loop, allowed_channels, origin_channel=None):
    """Return a tool executor that handles Discord-specific tools and delegates the rest."""

    def executor(tool_name, tool_input):
        if tool_name == "generate_image":
            # Optional cross-channel posting, whitelist-gated like the channel
            # tools; default destination is the originating channel/DM.
            target = origin_channel
            channel_name = (tool_input.get("channel_name") or "").strip()
            if channel_name:
                if channel_name not in allowed_channels:
                    return {"error": (
                        f"Channel '{channel_name}' is not in the allowed list. "
                        f"Allowed: {allowed_channels}. Omit channel_name to post "
                        "to the current channel."
                    )}
                target = discord.utils.get(
                    (c for c in client.get_all_channels() if isinstance(c, discord.TextChannel)),
                    name=channel_name,
                )
                if target is None:
                    return {"error": f"Channel '{channel_name}' not found on this server."}
            return _execute_generate_image(loop, target, tool_input)

        if tool_name not in ("send_channel_message", "read_channel_messages"):
            return execute_tool(tool_name, tool_input)

        channel_name = tool_input.get("channel_name", "")

        if channel_name not in allowed_channels:
            return {"error": f"Channel '{channel_name}' is not in the allowed list. Allowed: {allowed_channels}"}

        channel = discord.utils.get(
            (c for c in client.get_all_channels() if isinstance(c, discord.TextChannel)),
            name=channel_name,
        )
        if channel is None:
            return {"error": f"Channel '{channel_name}' not found on this server."}

        if tool_name == "send_channel_message":
            message = tool_input.get("message", "")
            # Discord rejects messages over 2000 chars; with a large output
            # budget the model can exceed that, so split into ordered chunks.
            chunks = [message[i:i + 2000] for i in range(0, len(message), 2000)] or [""]
            try:
                async def _send_all():
                    for chunk in chunks:
                        await channel.send(chunk)
                future = asyncio.run_coroutine_threadsafe(_send_all(), loop)
                future.result(timeout=30)
                return {"success": True, "channel": channel_name, "parts": len(chunks)}
            except Exception as exc:
                return {"error": f"Failed to send message to '{channel_name}': {exc}"}

        # read_channel_messages
        # Capped well below Bedrock's per-request 20-image total to leave
        # headroom for images already in the triggering conversation history.
        TOOL_MAX_IMAGES = 5
        limit = min(tool_input.get("limit", 20), 50)
        try:
            async def _fetch_history_and_images():
                msgs = [m async for m in channel.history(limit=limit)]
                chronological = list(reversed(msgs))
                # Walk newest-first so the most recent images win under the cap.
                fetched = {}  # msg.id -> [(filename, fmt, bytes)]
                count = 0
                for m in reversed(chronological):
                    if count >= TOOL_MAX_IMAGES:
                        break
                    for attachment in m.attachments:
                        if count >= TOOL_MAX_IMAGES:
                            break
                        if not _looks_like_image(attachment):
                            continue
                        if attachment.size > MAX_IMAGE_BYTES:
                            continue
                        try:
                            data = await attachment.read()
                        except Exception as exc:
                            logger.warning(
                                "Channel-tool image read failed for %s: %s",
                                attachment.filename, exc,
                            )
                            continue
                        fmt = _sniff_image_format(data)
                        if fmt is None:
                            continue
                        fetched.setdefault(m.id, []).append(
                            (attachment.filename, fmt, data)
                        )
                        count += 1
                return chronological, fetched

            future = asyncio.run_coroutine_threadsafe(_fetch_history_and_images(), loop)
            chronological, fetched = future.result(timeout=20)

            total_attachments = sum(len(m.attachments) for m in chronological)
            total_images = sum(len(v) for v in fetched.values())
            logger.info(
                "Channel-tool '%s': %d messages, %d total attachments, %d images sniffed",
                channel_name, len(chronological), total_attachments, total_images,
            )

            formatted = []
            for m in chronological:
                entry = {
                    "author": m.author.display_name,
                    "content": m.content,
                    "timestamp": m.created_at.isoformat(),
                }
                if m.id in fetched:
                    entry["image_attachments"] = [name for name, _, _ in fetched[m.id]]
                formatted.append(entry)

            # Return a content-blocks list so the loop in bedrock_converse forwards
            # text + image blocks to Bedrock instead of JSON-wrapping the dict.
            blocks = [{"text": json.dumps(
                {"channel": channel_name, "messages": formatted}, indent=2,
            )}]
            for m in chronological:
                for filename, fmt, data in fetched.get(m.id, []):
                    blocks.append({"text": (
                        f"\nImage attachment '{filename}' from "
                        f"{m.author.display_name} at {m.created_at.isoformat()}:"
                    )})
                    blocks.append({"image": {"format": fmt, "source": {"bytes": data}}})
            logger.info(
                "Channel-tool '%s' returning %d content blocks (%d image blocks)",
                channel_name, len(blocks),
                sum(1 for b in blocks if "image" in b),
            )
            return blocks
        except Exception as exc:
            return {"error": f"Failed to read messages from '{channel_name}': {exc}"}

    return executor


def _execute_generate_image(loop, origin_channel, tool_input):
    """Generate an image via Bedrock and post it to the originating channel.

    Returns a content-blocks list (text status + the image itself) so the model
    can see what it produced and caption it, mirroring read_channel_messages.
    """
    prompt = (tool_input.get("prompt") or "").strip()
    if not prompt:
        return {"error": "generate_image requires a non-empty prompt."}
    if origin_channel is None:
        return {"error": "No channel available to post the image to."}

    try:
        data = generate_image(
            prompt,
            negative_prompt=tool_input.get("negative_prompt"),
            orientation=tool_input.get("orientation", "square"),
        )
    except Exception as exc:
        logger.warning("Image generation failed: %s", exc)
        return {"error": f"Image generation failed: {type(exc).__name__}: {exc}"}

    filename = f"arcbot-{int(time.time())}.png"
    try:
        async def _post():
            await origin_channel.send(
                file=discord.File(io.BytesIO(data), filename=filename)
            )
        future = asyncio.run_coroutine_threadsafe(_post(), loop)
        future.result(timeout=30)
    except Exception as exc:
        logger.warning("Posting generated image failed: %s", exc)
        return {"error": f"Image was generated but posting to Discord failed: {exc}"}

    logger.info("Generated and posted image %s (%d bytes)", filename, len(data))
    return [
        {"text": json.dumps({
            "success": True,
            "filename": filename,
            "note": (
                "The image below was generated and already posted to the channel "
                "as an attachment - do NOT post it again. You may briefly caption "
                "or describe it in your reply."
            ),
        })},
        {"image": {"format": "png", "source": {"bytes": data}}},
    ]


# ── Discord Bot ──────────────────────────────────────────────────────────────


class ArcbotDiscord:
    """Discord bot that uses Bedrock Converse for response generation."""

    def __init__(self):
        intents = discord.Intents.default()
        intents.message_content = True
        intents.messages = True
        intents.dm_messages = True
        self.client = discord.Client(intents=intents)
        self.nickname = DISCORD_NICKNAME
        self._setup_events()

    def _setup_events(self):
        bot = self

        @self.client.event
        async def on_ready():
            if not bot.nickname:
                bot.nickname = bot.client.user.display_name
            logger.info("Discord bot '%s' connected as %s", bot.nickname, bot.client.user)

        @self.client.event
        async def on_message(message):
            await bot._handle_message(message)

    async def _handle_message(self, message):
        """Handle incoming Discord messages."""
        if message.author == self.client.user:
            return

        # Classify the trigger — mentions/replies/DMs are "direct" (always respond),
        # all other channel messages are "ambient" (model decides via [NO_RESPONSE]).
        is_mention = self.client.user in message.mentions
        is_reply = (message.reference and message.reference.resolved
                    and message.reference.resolved.author == self.client.user)
        is_dm = isinstance(message.channel, discord.DMChannel)
        is_direct = is_mention or is_reply or is_dm

        # Deny list check on message content and author
        deny_list = ENV["deny_list"]
        if deny_list:
            content_lower = message.content.lower()
            author_name = message.author.display_name.lower()
            for entry in deny_list:
                entry_lower = entry.lower()
                if entry_lower in content_lower or entry_lower in author_name:
                    logger.info("Skipping message from %s - deny list match: %s",
                                message.author.display_name, entry)
                    return

        # Response rate sampling (only for ambient messages — direct always passes)
        if not is_direct and random.random() >= ENV["response_rate"]:
            logger.info("Skipping message (response_rate=%.2f)", ENV["response_rate"])
            return

        # Don't show typing indicator for ambient messages (model will usually opt out)
        async with message.channel.typing() if is_direct else _noop_context():
            try:
                response = await self._generate_response(message, is_direct=is_direct)
                if not response or response.strip() == NO_RESPONSE_SENTINEL:
                    logger.info("Bot opted out of responding (NO_RESPONSE or empty)")
                    return

                # Split long messages (Discord limit is 2000 chars)
                use_reply = random.random() < 0.33
                for i in range(0, len(response), 2000):
                    chunk = response[i:i + 2000]
                    if use_reply:
                        await message.reply(chunk)
                    else:
                        await message.channel.send(chunk)

            except Exception as exc:
                logger.error("Error generating response: %s", exc, exc_info=True)
                await message.channel.send("Sorry, I encountered an error generating a response.")

    async def _generate_response(self, message, is_direct=True):
        """Generate a response using Bedrock Converse via the shared backend."""
        # Fetch recent channel history
        history = []
        try:
            async for msg in message.channel.history(limit=DISCORD_HISTORY_LIMIT):
                history.append(msg)
        except Exception as exc:
            logger.warning("Error fetching history: %s", exc)
            history = [message]

        history.reverse()

        # Pre-scan history newest-first to select up to MAX_IMAGES_PER_CALL most-recent
        # image attachments. The pre-scan filter is intentionally loose (extension or
        # content_type signal) since Discord lies about content_type; the real format
        # is sniffed from bytes in the build loop below.
        allowed_attachment_ids = set()
        image_count = 0
        for msg in reversed(history):
            if image_count >= MAX_IMAGES_PER_CALL:
                break
            # Never ingest the bot's own attachments (e.g. generated images):
            # they would become image blocks on ASSISTANT messages, which
            # Bedrock rejects - and an image-only bot message yields a
            # text-less assistant content list.
            if msg.author == self.client.user:
                continue
            for attachment in msg.attachments:
                if image_count >= MAX_IMAGES_PER_CALL:
                    break
                if not _looks_like_image(attachment):
                    continue
                if attachment.size > MAX_IMAGE_BYTES:
                    logger.info(
                        "Skipping oversized image attachment %s (%d bytes)",
                        attachment.filename, attachment.size,
                    )
                    continue
                allowed_attachment_ids.add(attachment.id)
                image_count += 1

        # Build Bedrock Converse messages from channel history
        messages = []
        for msg in history:
            if msg.author == self.client.user:
                role = "assistant"
                text = msg.content
            else:
                role = "user"
                content = msg.content
                # Remove bot mentions from content
                if self.client.user:
                    content = content.replace(f"<@{self.client.user.id}>", "").strip()
                text = f"{msg.author.display_name}: {content}"

            image_blocks = []
            for attachment in msg.attachments:
                if attachment.id not in allowed_attachment_ids:
                    continue
                try:
                    data = await attachment.read()
                except Exception as exc:
                    logger.warning(
                        "Failed to fetch image attachment %s: %s",
                        attachment.filename, exc,
                    )
                    continue
                fmt = _sniff_image_format(data)
                if fmt is None:
                    logger.warning(
                        "Skipping attachment %s: unrecognized image format "
                        "(Discord content_type=%r, %d bytes)",
                        attachment.filename, attachment.content_type, len(data),
                    )
                    continue
                image_blocks.append({"image": {"format": fmt, "source": {"bytes": data}}})

            if not text and not image_blocks:
                continue

            # Merge consecutive same-role messages: text concatenates into the
            # first text block (which is NOT necessarily content[0] - an
            # image-only message has no text block); images accumulate at the end.
            if messages and messages[-1]["role"] == role:
                merge_text_into_content(messages[-1]["content"], text)
                messages[-1]["content"].extend(image_blocks)
            else:
                new_content = [{"text": text}] if text else []
                new_content.extend(image_blocks)
                messages.append({"role": role, "content": new_content})

        if not messages:
            return None

        # Ensure last message is from user (Bedrock requirement)
        if messages[-1]["role"] != "user":
            messages.append({"role": "user", "content": [
                {"text": f"{message.author.display_name}: {message.content}"}
            ]})

        # Build system prompt with optional KB context and ambient instruction
        system_text = EFFECTIVE_SYSTEM_PROMPT or ""
        if not is_direct:
            ambient_instruction = (
                "\n\n## Ambient Mode\n"
                "You are observing a channel conversation — you were NOT directly mentioned, "
                "replied to, or messaged. Respond ONLY if you have something genuinely valuable "
                "to add. In the vast majority of cases, reply with exactly [NO_RESPONSE] and "
                "nothing else. Reserve real responses for moments where your knowledge is "
                "directly relevant and your input would be welcomed."
            )
            system_text = f"{system_text}{ambient_instruction}"
        system_text += (
            "\n\n## Response Opt-Out\n"
            "You always have the option to say nothing. If a conversation has run its "
            "course, if your reply would add no value, or if you find yourself about to "
            "write a closing platitude like \"I'm done here\" or \"This conversation is "
            "over\", reply with exactly [NO_RESPONSE] and nothing else instead. "
            "Silence is better than a hollow sign-off."
        )
        system_text += (
            "\n\n## Image Support\n"
            "When Discord users attach images to their messages, those images appear "
            "inline in the conversation history you receive. You can see them directly. "
            "Treat them as part of the conversation - describe, reason about, or quote "
            "text from them when relevant to the discussion. You can also CREATE "
            "images: when a user asks you to draw, render, or visualize something, "
            "call the generate_image tool with a rich visual prompt."
        )
        if ENV["knowledge_base_id"]:
            # Use the triggering message as the KB query
            kb_context = retrieve_kb_context(message.content, "")
            if kb_context:
                separator = "\n\n" if system_text else ""
                system_text = f"{system_text}{separator}## Knowledge Base Context\n{kb_context}"

        context_id = f"discord-{message.channel.id}-{message.id}"

        # Build tool list — shared defaults (whoami, query_iam_permissions, fetch_url)
        # plus image generation (always) and cross-channel messaging when configured.
        tools = list(TOOL_DEFINITIONS)
        tools.append(GENERATE_IMAGE_TOOL)
        if DISCORD_TOOL_CHANNELS:
            tools.append(READ_CHANNEL_MESSAGES_TOOL)
            tools.append(SEND_CHANNEL_MESSAGE_TOOL)
        loop = asyncio.get_event_loop()
        tool_executor = _make_tool_executor(
            self.client, loop, DISCORD_TOOL_CHANNELS,
            origin_channel=message.channel,
        )

        # Run Bedrock call in thread pool to avoid blocking the event loop
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None,
            lambda: bedrock_converse(
                messages, context_id, system_text=system_text,
                tools=tools, tool_executor=tool_executor,
            ),
        )
        return response

    def run(self):
        """Start the bot (blocking)."""
        self.client.run(DISCORD_TOKEN)


# ── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    bot = ArcbotDiscord()
    bot.run()
