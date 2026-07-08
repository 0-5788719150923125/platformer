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
import re
import threading

import discord


@contextlib.asynccontextmanager
async def _noop_context():
    """No-op async context manager — replaces typing indicator for ambient messages."""
    yield

import io
import time

from ai_backend import (
    annotate_image,
    bedrock_converse,
    compose_system_prompt,
    execute_tool,
    generate_image,
    generate_overlay,
    merge_text_into_content,
    load_env,
    load_system_prompt,
    retrieve_kb_context,
    IMAGE_ORIENTATIONS,
    is_opt_out,
    OVERLAY_MAX_DENSITY,
    OVERLAY_MAX_ELEMENTS,
    OVERLAY_MAX_REFERENCE_IMAGES,
    OVERLAY_MAX_VARIANTS,
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

# Bedrock Converse caps: 20 images per request, and 5 MiB (5,242,880 bytes)
# per image. Critically, that 5 MiB ceiling is enforced on the *base64-encoded*
# payload, which is 4/3 the size of the raw bytes. So the largest raw image we
# can safely send is 5,242,880 * 3/4 = 3,932,160 bytes. We compare raw sizes
# (Discord attachment.size / generated len(data)) everywhere, so the threshold
# must be the raw-equivalent, not 5 MB - otherwise a ~4 MB raw image passes our
# check but Bedrock rejects it (base64 ~5.4 MB) with a ValidationException that
# poisons every subsequent reply re-including that image.
MAX_IMAGES_PER_CALL = 20
BEDROCK_IMAGE_B64_LIMIT = 5 * 1024 * 1024  # 5,242,880 bytes, base64-encoded
MAX_IMAGE_BYTES = BEDROCK_IMAGE_B64_LIMIT * 3 // 4 - 16_384  # raw-byte ceiling, w/ margin

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

# ── Document (PDF) support ───────────────────────────────────────────────────

# Bedrock Converse caps: 5 documents per request, 4.5 MiB per document. As with
# images (above), that ceiling is enforced on the *base64-encoded* payload - the
# AWS docs even note metadata/encoding can push an apparently-sub-4.5 MB file
# over - so the largest raw document we can safely send is 4.5 MiB * 3/4, minus
# a margin. Sending an oversized document triggers the same ValidationException
# that poisons every subsequent reply re-including it from history.
MAX_DOCUMENTS_PER_CALL = 5
BEDROCK_DOCUMENT_B64_LIMIT = 4_718_592  # 4.5 MiB (4.5 * 1024 * 1024), base64-encoded
MAX_DOCUMENT_BYTES = BEDROCK_DOCUMENT_B64_LIMIT * 3 // 4 - 16_384  # raw-byte ceiling, w/ margin

# Only PDF for now (Converse also accepts csv/doc/docx/xls/xlsx/html/txt/md).
# Discord's content_type is unreliable, so this pre-scan is advisory; the real
# format is confirmed by sniffing magic bytes in _sniff_document_format.
DOCUMENT_EXTENSIONS = frozenset({".pdf"})

# Bedrock document names allow only alphanumerics, single whitespace, hyphens,
# parentheses and square brackets. Anything else is replaced with a space.
_DOC_NAME_DISALLOWED = re.compile(r"[^A-Za-z0-9 ()\[\]-]+")


def _looks_like_pdf(attachment):
    """Loose pre-scan filter: is this attachment plausibly a PDF?"""
    content_type = (attachment.content_type or "").split(";")[0].strip().lower()
    if content_type == "application/pdf":
        return True
    filename = (attachment.filename or "").lower()
    return any(filename.endswith(ext) for ext in DOCUMENT_EXTENSIONS)


def _sniff_document_format(data):
    """Detect a Bedrock-compatible document format from raw bytes.

    Returns 'pdf' or None. Bedrock validates the declared format against the
    actual bytes, so magic-byte sniffing is the authoritative source of truth -
    filename and content_type can lie. The PDF spec allows a few leading bytes
    before the "%PDF-" header, so we scan the first 1 KiB rather than byte 0.
    """
    if not data:
        return None
    if b"%PDF-" in data[:1024]:
        return "pdf"
    return None


def _safe_document_name(filename, used_names, fallback="document"):
    """Coerce a Discord filename into a unique, Bedrock-legal document name.

    Drops the extension, replaces disallowed characters with spaces, collapses
    whitespace runs, and disambiguates collisions with a " (n)" suffix so every
    document in a request gets a distinct name. Mutates used_names.
    """
    base = (filename or "").rsplit(".", 1)[0]
    cleaned = " ".join(_DOC_NAME_DISALLOWED.sub(" ", base).split()) or fallback
    name = cleaned
    n = 2
    while name in used_names:
        name = f"{cleaned} ({n})"
        n += 1
    used_names.add(name)
    return name


def _split_message(text, limit=2000):
    """Split text into Discord-legal chunks, breaking at natural boundaries.

    Prefers (in order) a blank line, a single newline, a sentence-ending
    punctuation mark followed by whitespace, or a plain space - all searched
    for backward from the limit so we never split mid-word if a better break
    point exists. Falls back to a hard cut only when a single "word" (or the
    first line) exceeds the limit on its own.
    """
    chunks = []
    while len(text) > limit:
        window = text[:limit]
        break_at = None
        for pattern in ("\n\n", "\n"):
            idx = window.rfind(pattern)
            if idx > 0:
                break_at = idx + len(pattern)
                break
        if break_at is None:
            matches = list(re.finditer(r"[.!?][\"')\]]?\s", window))
            if matches:
                break_at = matches[-1].end()
        if break_at is None:
            idx = window.rfind(" ")
            if idx > 0:
                break_at = idx + 1
        if break_at is None:
            break_at = limit
        chunks.append(text[:break_at].rstrip("\n"))
        text = text[break_at:].lstrip("\n")
    if text:
        chunks.append(text)
    return chunks or [""]

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
            "Read recent messages from a Discord channel, including each "
            "message's ID (needed by edit_message). Use this to understand "
            "what's being discussed before sending a message, or to find the "
            "ID of one of your own messages. Omit channel_name to read the "
            "current channel; otherwise only whitelisted channels are available."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "channel_name": {
                        "type": "string",
                        "description": (
                            "Optional: name of the Discord channel to read. "
                            "Omit to read the current channel/DM."
                        ),
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Number of recent messages to fetch (default 20, max 50).",
                    },
                },
                "required": [],
            }
        },
    }
}

EDIT_MESSAGE_TOOL = {
    "toolSpec": {
        "name": "edit_message",
        "description": (
            "Edit one of your own previous Discord messages, replacing its text "
            "with new content. Discord only allows you to edit messages you "
            "sent yourself. Find the message_id of the target message with "
            "read_channel_messages (your own messages are marked author_is_you). "
            "By default the message is looked up in the current channel; pass "
            "channel_name to edit a message in another whitelisted channel."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "message_id": {
                        "type": "string",
                        "description": "ID of the message to edit (numeric Discord snowflake).",
                    },
                    "new_message": {
                        "type": "string",
                        "description": (
                            "The replacement text. Replaces the entire message "
                            "content (max 2000 characters)."
                        ),
                    },
                    "channel_name": {
                        "type": "string",
                        "description": (
                            "Optional: name of the whitelisted channel containing "
                            "the message. Omit for the current channel/DM."
                        ),
                    },
                },
                "required": ["message_id", "new_message"],
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


ANNOTATE_IMAGE_TOOL = {
    "toolSpec": {
        "name": "annotate_image",
        "description": (
            "Draw one or more bright-green line segments over an image "
            "already in this conversation, and post the annotated result to "
            "Discord as a new attachment. Use this to visually point out a "
            "shape, path, or set of connections on an image you've seen - "
            "e.g. connecting stars into a constellation, tracing a route, "
            "underlining a region. Coordinates are normalized to the "
            "image's own width/height (0.0 to 1.0, origin at the top-left "
            "corner) - read them off the image as you view it; they don't "
            "need to be pixel-exact. By default this annotates the most "
            "recent image attachment in the conversation; pass message_id "
            "(from read_channel_messages) to target a different one."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "lines": {
                        "type": "array",
                        "description": "Line segments to draw, in normalized 0.0-1.0 coordinates.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "x1": {"type": "number", "description": "Start X, 0.0-1.0."},
                                "y1": {"type": "number", "description": "Start Y, 0.0-1.0."},
                                "x2": {"type": "number", "description": "End X, 0.0-1.0."},
                                "y2": {"type": "number", "description": "End Y, 0.0-1.0."},
                            },
                            "required": ["x1", "y1", "x2", "y2"],
                        },
                    },
                    "message_id": {
                        "type": "string",
                        "description": (
                            "Optional: numeric Discord ID of the message whose "
                            "image attachment should be annotated. Omit to use "
                            "the most recent image attachment in this channel."
                        ),
                    },
                },
                "required": ["lines"],
            }
        },
    }
}


GENERATE_OVERLAY_TOOL = {
    "toolSpec": {
        "name": "generate_overlay",
        "description": (
            "Generatively decorate an image already in this conversation with "
            "small hand-drawn-style elements - e.g. scattering handwritten "
            "poetry scribbles, geometric line patterns, or little doodle "
            "icons/creatures across it. Each element type is independently "
            "generated (several isolated variants, keyed to transparency) "
            "then scattered across a region you specify with natural size, "
            "rotation, and position variation. Any element can optionally be "
            "conditioned on other image attachments in this conversation via "
            "reference_message_ids, so its style/content matches a photo the "
            "user pointed to instead of relying on the text description "
            "alone. IMPORTANT: this runs multiple background image "
            "generations and can take a while (well past a normal reply) - "
            "it posts the finished image directly to the channel when done "
            "rather than returning it through this tool call, so tell the "
            "user it's in progress and do not call this tool again for the "
            "same request while waiting. List elements background-to-"
            "foreground (the first entry is drawn first, underneath the "
            "rest)."
        ),
        "inputSchema": {
            "json": {
                "type": "object",
                "properties": {
                    "elements": {
                        "type": "array",
                        "description": (
                            "One entry per distinct visual element type to "
                            "generate and scatter, background-to-foreground."
                        ),
                        "items": {
                            "type": "object",
                            "properties": {
                                "description": {
                                    "type": "string",
                                    "description": (
                                        "What this one element looks like, e.g. "
                                        "'a short line of cursive handwritten "
                                        "poetry', 'a simple geometric line "
                                        "tessellation', 'a small doodle of a "
                                        "cat'. Generated in isolation on a "
                                        "white background, so describe just "
                                        "the single subject/motif, not a scene."
                                    ),
                                },
                                "region": {
                                    "type": "array",
                                    "items": {"type": "number"},
                                    "description": (
                                        "[x, y, width, height], normalized "
                                        "0.0-1.0, the area of the base image "
                                        "to scatter instances within. Defaults "
                                        "to the whole image."
                                    ),
                                },
                                "scale": {
                                    "type": "number",
                                    "description": (
                                        "Target size of one instance, as a "
                                        "fraction of the base image's shorter "
                                        "dimension (default 0.15). Actual "
                                        "instances vary +/-20% around this."
                                    ),
                                },
                                "density": {
                                    "type": "integer",
                                    "description": (
                                        f"How many scattered copies of this "
                                        f"element to place (default 1, max "
                                        f"{OVERLAY_MAX_DENSITY})."
                                    ),
                                },
                                "variants": {
                                    "type": "integer",
                                    "description": (
                                        "How many independent samples to "
                                        f"generate for this element before "
                                        f"scattering copies (default 3, max "
                                        f"{OVERLAY_MAX_VARIANTS})."
                                    ),
                                },
                                "blend_mode": {
                                    "type": "string",
                                    "enum": ["normal", "multiply", "screen"],
                                    "description": (
                                        "How each instance blends onto the "
                                        "image below it (default normal)."
                                    ),
                                },
                                "reference_message_ids": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "description": (
                                        "Optional: numeric Discord message IDs "
                                        "(1-{max} images total) whose image "
                                        "attachments this element's generated "
                                        "samples should be conditioned on - use "
                                        "this when the user wants an element to "
                                        "match the style or content of another "
                                        "photo they shared (e.g. 'make the "
                                        "doodles look like the sketch in that "
                                        "other image'), rather than describing "
                                        "the look in words alone. The "
                                        "'description' field is still used as "
                                        "the accompanying text prompt."
                                    ).format(max=OVERLAY_MAX_REFERENCE_IMAGES),
                                },
                                "similarity_strength": {
                                    "type": "number",
                                    "description": (
                                        "Only used with reference_message_ids: "
                                        "how closely samples should follow the "
                                        "reference image(s) vs. the text "
                                        "description (0.2-1.0, default 0.7). "
                                        "Lower is more random/text-driven, "
                                        "higher stays closer to the reference."
                                    ),
                                },
                            },
                            "required": ["description"],
                        },
                    },
                    "message_id": {
                        "type": "string",
                        "description": (
                            "Optional: numeric Discord ID of the message "
                            "whose image should be the base. Omit to use the "
                            "most recent image attachment in this channel."
                        ),
                    },
                },
                "required": ["elements"],
            }
        },
    }
}


def _make_tool_executor(client, loop, allowed_channels, origin_channel=None):
    """Return a tool executor that handles Discord-specific tools and delegates the rest."""

    def _resolve_channel(channel_name):
        """Resolve a tool's channel argument to a channel object.

        Empty/missing name means the originating channel/DM; a name must be on
        the whitelist and exist on the server. Returns (channel, error_dict) -
        exactly one is None.
        """
        if not channel_name:
            if origin_channel is None:
                return None, {"error": "No current channel available; pass channel_name."}
            return origin_channel, None
        if channel_name not in allowed_channels:
            return None, {"error": f"Channel '{channel_name}' is not in the allowed list. Allowed: {allowed_channels}"}
        channel = discord.utils.get(
            (c for c in client.get_all_channels() if isinstance(c, discord.TextChannel)),
            name=channel_name,
        )
        if channel is None:
            return None, {"error": f"Channel '{channel_name}' not found on this server."}
        return channel, None

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

        if tool_name == "annotate_image":
            return _execute_annotate_image(client, loop, origin_channel, tool_input)

        if tool_name == "generate_overlay":
            return _execute_generate_overlay(client, loop, origin_channel, tool_input)

        if tool_name == "edit_message":
            return _execute_edit_message(client, loop, _resolve_channel, tool_input)

        if tool_name not in ("send_channel_message", "read_channel_messages"):
            return execute_tool(tool_name, tool_input)

        channel_name = (tool_input.get("channel_name") or "").strip()

        # send_channel_message is for OTHER channels only (replying in the
        # current one is just a normal response), so its channel_name stays
        # mandatory; read may target the current channel by omitting it.
        if tool_name == "send_channel_message" and not channel_name:
            return {"error": "send_channel_message requires channel_name."}

        channel, err = _resolve_channel(channel_name)
        if err:
            return err

        if tool_name == "send_channel_message":
            message = tool_input.get("message", "")
            # Discord rejects messages over 2000 chars; with a large output
            # budget the model can exceed that, so split into ordered chunks
            # at natural boundaries (paragraph/line/sentence/word) instead of
            # cutting mid-word.
            chunks = _split_message(message)
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
        channel_label = channel_name or getattr(channel, "name", None) or "current channel"
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
                channel_label, len(chronological), total_attachments, total_images,
            )

            formatted = []
            for m in chronological:
                entry = {
                    "message_id": str(m.id),
                    "author": m.author.display_name,
                    "content": m.content,
                    "timestamp": m.created_at.isoformat(),
                }
                if m.author == client.user:
                    entry["author_is_you"] = True
                if m.id in fetched:
                    entry["image_attachments"] = [name for name, _, _ in fetched[m.id]]
                formatted.append(entry)

            # Return a content-blocks list so the loop in bedrock_converse forwards
            # text + image blocks to Bedrock instead of JSON-wrapping the dict.
            blocks = [{"text": json.dumps(
                {"channel": channel_label, "messages": formatted}, indent=2,
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
                channel_label, len(blocks),
                sum(1 for b in blocks if "image" in b),
            )
            return blocks
        except Exception as exc:
            return {"error": f"Failed to read messages from '{channel_label}': {exc}"}

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

    # Echo the image back to the model only when it fits Bedrock Converse's
    # 5 MB per-image cap - large generations (common at landscape/portrait
    # sizes) post to Discord fine but would fail the next Converse call.
    if len(data) <= MAX_IMAGE_BYTES:
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
    return {
        "success": True,
        "filename": filename,
        "note": (
            "The image was generated and posted to the channel as an attachment. "
            "It is too large to show you here, so caption it from your own prompt "
            "if needed - do NOT retry or post it again."
        ),
    }


def _resolve_source_image(client, loop, origin_channel, message_id, timeout=20):
    """Locate a base image attachment to operate on: by explicit message_id,
    or (if omitted) the most recent qualifying image in the channel's recent
    history. Shared by annotate_image and generate_overlay so both target
    "the image the user/model is currently looking at" the same way.

    When falling back to "most recent" (no message_id given), the bot's own
    attachments are skipped - otherwise, once the bot has posted any image of
    its own (a generate_image/annotate_image/generate_overlay result), that
    becomes the newest image in the channel and every subsequent
    default-target call silently re-targets it instead of the user's actual
    photo. An explicit message_id is honored as given (the model may
    legitimately want to re-annotate its own prior output), so this only
    guards the auto-pick path, mirroring the same self-exclusion the vision
    history pre-scan in _generate_response already applies.

    Uses the same loose-filter-then-sniff pattern as that pre-scan. Returns
    (data, source_message_id, None) on success, or (None, None, error_message)
    on failure - callers can wrap the error directly into a tool-result dict.
    """
    if message_id and not message_id.isdigit():
        return None, None, f"message_id must be a numeric Discord message ID, got: {message_id!r}"

    try:
        async def _find_source():
            if message_id:
                try:
                    candidates = [await origin_channel.fetch_message(int(message_id))]
                except discord.NotFound:
                    return None, f"Message {message_id} not found in this channel."
            else:
                candidates = [
                    m async for m in origin_channel.history(limit=DISCORD_HISTORY_LIMIT)
                    if m.author != client.user
                ]

            for msg in candidates:
                for attachment in msg.attachments:
                    if not _looks_like_image(attachment):
                        continue
                    if attachment.size > MAX_IMAGE_BYTES:
                        continue
                    data = await attachment.read()
                    fmt = _sniff_image_format(data)
                    if fmt is None:
                        continue
                    return (data, msg.id), None
            return None, "No suitable image attachment found in this conversation."

        future = asyncio.run_coroutine_threadsafe(_find_source(), loop)
        found, err = future.result(timeout=timeout)
        if err:
            logger.warning("Source-image lookup failed: %s", err)
            return None, None, err
        data, source_msg_id = found
        logger.info(
            "Resolved source image: message %s (%s)",
            source_msg_id, "explicit message_id" if message_id else "most recent in history",
        )
        return data, source_msg_id, None
    except Exception as exc:
        logger.warning("Source-image lookup raised: %s", exc, exc_info=True)
        return None, None, f"Failed to locate source image: {exc}"


def _execute_annotate_image(client, loop, origin_channel, tool_input):
    """Draw line-segment overlays on a recent image and post the result.

    Returns a content-blocks list (text status + the annotated image) so the
    model can see what it produced, mirroring generate_image.
    """
    if origin_channel is None:
        return {"error": "No channel available to annotate an image in."}

    lines = tool_input.get("lines")
    if not isinstance(lines, list) or not lines:
        return {"error": "annotate_image requires a non-empty 'lines' array."}

    message_id = str(tool_input.get("message_id") or "").strip()
    data, source_msg_id, err = _resolve_source_image(client, loop, origin_channel, message_id)
    if err:
        return {"error": err}

    try:
        result = annotate_image(data, lines)
    except Exception as exc:
        logger.warning("Image annotation failed: %s", exc)
        return {"error": f"Image annotation failed: {type(exc).__name__}: {exc}"}

    filename = f"arcbot-annotated-{int(time.time())}.png"
    try:
        async def _post():
            await origin_channel.send(
                file=discord.File(io.BytesIO(result), filename=filename)
            )
        future = asyncio.run_coroutine_threadsafe(_post(), loop)
        future.result(timeout=30)
    except Exception as exc:
        logger.warning("Posting annotated image failed: %s", exc)
        return {"error": f"Image was annotated but posting to Discord failed: {exc}"}

    logger.info(
        "Annotated image from message %s and posted %s (%d bytes)",
        source_msg_id, filename, len(result),
    )

    # Echo back to the model only when it fits Bedrock Converse's 5 MB cap,
    # same rationale as _execute_generate_image.
    if len(result) <= MAX_IMAGE_BYTES:
        return [
            {"text": json.dumps({
                "success": True,
                "filename": filename,
                "note": (
                    "The annotated image below was generated and already "
                    "posted to the channel as an attachment - do NOT post "
                    "it again."
                ),
            })},
            {"image": {"format": "png", "source": {"bytes": result}}},
        ]
    return {
        "success": True,
        "filename": filename,
        "note": (
            "The annotated image was posted to the channel as an "
            "attachment. It is too large to show you here - do NOT retry "
            "or post it again."
        ),
    }


def _resolve_element_references(loop, origin_channel, elements, timeout=30):
    """Resolve each element's optional reference_message_ids to raw image bytes.

    Runs synchronously before the background pipeline starts (all Discord
    fetches here are fast) so a bad reference ID fails the tool call
    immediately with a normal error, the same way the base-image lookup
    does, instead of surfacing deep inside a background job. Returns a new
    elements list where each dict gains a "_reference_images" key (a list of
    raw bytes, empty if the element had no reference_message_ids), or
    (None, error_message) on failure.
    """
    for el in elements:
        ref_ids = el.get("reference_message_ids") or []
        if not isinstance(ref_ids, list):
            return None, "reference_message_ids must be an array of message IDs."
        if len(ref_ids) > OVERLAY_MAX_REFERENCE_IMAGES:
            return None, (
                f"reference_message_ids supports at most "
                f"{OVERLAY_MAX_REFERENCE_IMAGES} images per element, got {len(ref_ids)}."
            )
        for rid in ref_ids:
            if not str(rid).strip().isdigit():
                return None, f"reference_message_ids must be numeric Discord message IDs, got: {rid!r}"

    try:
        async def _resolve_all():
            resolved = []
            for el in elements:
                ref_ids = el.get("reference_message_ids") or []
                images = []
                for rid in ref_ids:
                    try:
                        msg = await origin_channel.fetch_message(int(rid))
                    except discord.NotFound:
                        return None, f"Reference message {rid} not found in this channel."
                    found = None
                    for attachment in msg.attachments:
                        if not _looks_like_image(attachment):
                            continue
                        if attachment.size > MAX_IMAGE_BYTES:
                            continue
                        data = await attachment.read()
                        if _sniff_image_format(data) is None:
                            continue
                        found = data
                        break
                    if found is None:
                        return None, f"Reference message {rid} has no recognized image attachment."
                    images.append(found)
                resolved.append({**el, "_reference_images": images})
            return resolved, None

        future = asyncio.run_coroutine_threadsafe(_resolve_all(), loop)
        resolved, err = future.result(timeout=timeout)
        if err:
            logger.warning("Reference-image lookup failed: %s", err)
            return None, err
        return resolved, None
    except Exception as exc:
        logger.warning("Reference-image lookup raised: %s", exc, exc_info=True)
        return None, f"Failed to resolve reference images: {exc}"


def _execute_generate_overlay(client, loop, origin_channel, tool_input):
    """Validate input, resolve the base image, then run the (slow) generative
    overlay pipeline in a background thread and return immediately.

    Unlike every other tool here, this does NOT block until the work is
    done: a request with several element types x several variants each is
    many sequential Bedrock image-gen calls and can easily run past a minute,
    well beyond what's reasonable to hold up a single Converse tool-call
    turn for. The base image is still resolved synchronously (one cheap
    Discord fetch) so a bad request fails fast with a normal tool error
    instead of silently starting a background job for nothing; only the
    actual generation/compositing runs in the background thread, posting
    directly to Discord (success or failure) once finished.
    """
    if origin_channel is None:
        return {"error": "No channel available to post the result to."}

    elements = tool_input.get("elements")
    if not isinstance(elements, list) or not elements:
        return {"error": "generate_overlay requires a non-empty 'elements' array."}
    if len(elements) > OVERLAY_MAX_ELEMENTS:
        return {"error": f"Too many element types ({len(elements)}); max {OVERLAY_MAX_ELEMENTS}."}

    message_id = str(tool_input.get("message_id") or "").strip()
    data, source_msg_id, err = _resolve_source_image(client, loop, origin_channel, message_id)
    if err:
        return {"error": err}

    elements, err = _resolve_element_references(loop, origin_channel, elements)
    if err:
        return {"error": err}

    def _run_pipeline():
        try:
            result = generate_overlay(data, elements)
        except Exception as exc:
            logger.warning("Generative overlay pipeline failed: %s", exc)
            async def _post_error():
                await origin_channel.send(
                    f"Sorry, the overlay generation failed: {type(exc).__name__}: {exc}"
                )
            asyncio.run_coroutine_threadsafe(_post_error(), loop)
            return

        filename = f"arcbot-overlay-{int(time.time())}.png"
        try:
            async def _post_result():
                await origin_channel.send(
                    file=discord.File(io.BytesIO(result), filename=filename)
                )
            future = asyncio.run_coroutine_threadsafe(_post_result(), loop)
            future.result(timeout=30)
            logger.info(
                "Overlay pipeline finished (source message %s), posted %s (%d bytes)",
                source_msg_id, filename, len(result),
            )
        except Exception as exc:
            logger.warning("Posting overlay result failed: %s", exc)

    threading.Thread(target=_run_pipeline, daemon=True, name="generate-overlay").start()

    total_calls = sum(
        max(1, min(OVERLAY_MAX_VARIANTS, int(el.get("variants", 3))))
        for el in elements
    )
    return {
        "success": True,
        "status": "started",
        "note": (
            f"Started generating {len(elements)} overlay element type(s) "
            f"(~{total_calls} image generations) in the background - this "
            "can take a while. The finished image will be posted directly "
            "to this channel when ready. Do not call this tool again for "
            "the same request; just let the user know it's in progress."
        ),
    }


def _execute_edit_message(client, loop, resolve_channel, tool_input):
    """Edit one of the bot's own messages in place (edit_message tool).

    Discord's API only permits a bot to edit messages it authored; we check
    authorship before calling edit so the model gets a clear error instead of
    an opaque 403. Edits replace the whole message, and a single message cannot
    be split, so over-length replacements are rejected rather than truncated.
    """
    message_id = str(tool_input.get("message_id") or "").strip()
    if not message_id.isdigit():
        return {"error": f"message_id must be a numeric Discord message ID, got: {message_id!r}"}
    new_message = (tool_input.get("new_message") or "").strip()
    if not new_message:
        return {"error": "new_message must be non-empty."}
    if len(new_message) > 2000:
        return {"error": (
            f"new_message is {len(new_message)} characters; Discord caps a "
            "single message at 2000. Shorten the replacement text."
        )}

    channel, err = resolve_channel((tool_input.get("channel_name") or "").strip())
    if err:
        return err
    channel_label = getattr(channel, "name", None) or "current channel"

    try:
        async def _edit():
            try:
                msg = await channel.fetch_message(int(message_id))
            except discord.NotFound:
                return {"error": f"Message {message_id} not found in '{channel_label}'."}
            if msg.author != client.user:
                return {"error": (
                    f"Message {message_id} was sent by {msg.author.display_name}, "
                    "not you. You can only edit your own messages."
                )}
            await msg.edit(content=new_message)
            return {"success": True, "message_id": message_id, "channel": channel_label}

        future = asyncio.run_coroutine_threadsafe(_edit(), loop)
        result = future.result(timeout=30)
        if result.get("success"):
            logger.info("Edited message %s in '%s' (%d chars)",
                        message_id, channel_label, len(new_message))
        return result
    except Exception as exc:
        return {"error": f"Failed to edit message {message_id}: {exc}"}


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
                if is_opt_out(response):
                    logger.info("Bot opted out of responding (NO_RESPONSE or empty)")
                    return

                # Split long messages (Discord limit is 2000 chars), breaking
                # at natural boundaries instead of cutting mid-word.
                use_reply = random.random() < 0.33
                for chunk in _split_message(response):
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

        # Same pre-scan for PDF documents (independent cap; documents only attach
        # to user messages, so the bot's own attachments are skipped as above).
        allowed_document_ids = set()
        document_count = 0
        for msg in reversed(history):
            if document_count >= MAX_DOCUMENTS_PER_CALL:
                break
            if msg.author == self.client.user:
                continue
            for attachment in msg.attachments:
                if document_count >= MAX_DOCUMENTS_PER_CALL:
                    break
                if not _looks_like_pdf(attachment):
                    continue
                if attachment.size > MAX_DOCUMENT_BYTES:
                    logger.info(
                        "Skipping oversized document attachment %s (%d bytes)",
                        attachment.filename, attachment.size,
                    )
                    continue
                allowed_document_ids.add(attachment.id)
                document_count += 1

        # Build Bedrock Converse messages from channel history
        messages = []
        used_doc_names = set()
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

            document_blocks = []
            for attachment in msg.attachments:
                if attachment.id not in allowed_document_ids:
                    continue
                try:
                    data = await attachment.read()
                except Exception as exc:
                    logger.warning(
                        "Failed to fetch document attachment %s: %s",
                        attachment.filename, exc,
                    )
                    continue
                fmt = _sniff_document_format(data)
                if fmt is None:
                    logger.warning(
                        "Skipping attachment %s: unrecognized document format "
                        "(Discord content_type=%r, %d bytes)",
                        attachment.filename, attachment.content_type, len(data),
                    )
                    continue
                name = _safe_document_name(attachment.filename, used_doc_names)
                document_blocks.append(
                    {"document": {"format": fmt, "name": name, "source": {"bytes": data}}}
                )

            if not text and not image_blocks and not document_blocks:
                continue

            # Merge consecutive same-role messages: text concatenates into the
            # first text block (which is NOT necessarily content[0] - an
            # image-only message has no text block); images and documents
            # accumulate at the end. Bedrock requires any content array holding
            # a document to also hold a text block, so synthesize one if the
            # message had no text (user-message text always carries the author
            # prefix, so this is a belt-and-suspenders guard).
            if messages and messages[-1]["role"] == role:
                merge_text_into_content(messages[-1]["content"], text)
                messages[-1]["content"].extend(image_blocks)
                messages[-1]["content"].extend(document_blocks)
            else:
                new_content = [{"text": text}] if text else []
                new_content.extend(image_blocks)
                new_content.extend(document_blocks)
                if document_blocks and not any("text" in b for b in new_content):
                    new_content.insert(0, {"text": f"{msg.author.display_name} attached a document."})
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
            "call the generate_image tool with a rich visual prompt. You can "
            "ANNOTATE an image already in the conversation: when a user asks you to "
            "point out, circle, connect, or trace something on an image they shared "
            "(e.g. drawing lines between stars to form a constellation), call the "
            "annotate_image tool with normalized line coordinates read off the image. "
            "You can also generatively DECORATE an image with scattered hand-drawn-"
            "style elements (poetry scribbles, geometric patterns, small doodles) "
            "using the generate_overlay tool - it runs in the background and posts "
            "the result to the channel itself, so tell the user it's working on it "
            "rather than waiting for a return value."
        )
        system_text += (
            "\n\n## Message Editing\n"
            "You can revise your own previous messages with the edit_message "
            "tool - useful when asked to fix a typo or correct a mistake in "
            "something you already posted. First call read_channel_messages "
            "(omitting channel_name reads the current channel) to find the "
            "message_id of your message (yours are marked author_is_you), then "
            "call edit_message with the full replacement text. You can only "
            "edit messages you sent yourself."
        )
        if ENV["knowledge_base_id"]:
            # Use the triggering message as the KB query
            kb_context = retrieve_kb_context(message.content, "")
            if kb_context:
                separator = "\n\n" if system_text else ""
                system_text = f"{system_text}{separator}## Knowledge Base Context\n{kb_context}"

        context_id = f"discord-{message.channel.id}-{message.id}"

        # Build tool list — shared defaults (whoami, query_iam_permissions, fetch_url)
        # plus image generation, channel reading, and self-message editing
        # (always; read/edit default to the current channel) and cross-channel
        # sending when whitelisted channels are configured.
        tools = list(TOOL_DEFINITIONS)
        tools.append(GENERATE_IMAGE_TOOL)
        tools.append(ANNOTATE_IMAGE_TOOL)
        tools.append(GENERATE_OVERLAY_TOOL)
        tools.append(READ_CHANNEL_MESSAGES_TOOL)
        tools.append(EDIT_MESSAGE_TOOL)
        if DISCORD_TOOL_CHANNELS:
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
