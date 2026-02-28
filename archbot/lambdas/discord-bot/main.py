"""archbot Discord Bot - Standalone container process.

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

from ai_backend import (
    bedrock_converse,
    compose_system_prompt,
    load_env,
    load_system_prompt,
    retrieve_kb_context,
    NO_RESPONSE_SENTINEL,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("archbot.discord")

# ── Environment ──────────────────────────────────────────────────────────────

ENV = load_env()
SYSTEM_PROMPT = load_system_prompt()
EFFECTIVE_SYSTEM_PROMPT = compose_system_prompt(SYSTEM_PROMPT, ENV["deny_list"])

DISCORD_TOKEN = os.environ["DISCORD_TOKEN"]
BOT_NAME = os.environ.get("BOT_NAME", "archbot")
DISCORD_NICKNAME = os.environ.get("DISCORD_NICKNAME", "")
DISCORD_HISTORY_LIMIT = int(os.environ.get("DISCORD_HISTORY_LIMIT", "20"))


# ── Discord Bot ──────────────────────────────────────────────────────────────


class ArchbotDiscord:
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

            if not text:
                continue

            # Merge consecutive same-role messages
            if messages and messages[-1]["role"] == role:
                messages[-1]["content"][0]["text"] += f"\n\n{text}"
            else:
                messages.append({"role": role, "content": [{"text": text}]})

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
        if ENV["knowledge_base_id"]:
            # Use the triggering message as the KB query
            kb_context = retrieve_kb_context(message.content, "")
            if kb_context:
                separator = "\n\n" if system_text else ""
                system_text = f"{system_text}{separator}## Knowledge Base Context\n{kb_context}"

        context_id = f"discord-{message.channel.id}-{message.id}"

        # Run Bedrock call in thread pool to avoid blocking the event loop
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None,
            lambda: bedrock_converse(
                messages, context_id, system_text=system_text, tools=[]
            ),
        )
        return response

    def run(self):
        """Start the bot (blocking)."""
        self.client.run(DISCORD_TOKEN)


# ── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    bot = ArchbotDiscord()
    bot.run()
