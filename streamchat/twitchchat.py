#!/usr/bin/env python3

import asyncio
import os
import requests
import signal
from twitchio.ext import commands
from datetime import datetime
import colorama
from colorama import Fore, Style
import aioconsole  # For async console input

# Initialize colorama for colored terminal output
colorama.init()

class TwitchBot(commands.Bot):
    def __init__(self):
        # Get credentials from environment variables
        self.access_token = os.getenv('TWITCH_OAUTH_TOKEN')
        self.refresh_token = os.getenv('TWITCH_REFRESH_TOKEN')
        self.client_id = os.getenv('TWITCH_CLIENT_ID')
        self.client_secret = os.getenv('TWITCH_CLIENT_SECRET')
        self.channel = os.getenv('TWITCH_CHANNEL')
        
        # Check for missing variables
        missing_vars = []
        if not self.access_token:
            missing_vars.append('TWITCH_OAUTH_TOKEN')
        if not self.refresh_token:
            missing_vars.append('TWITCH_REFRESH_TOKEN')
        if not self.client_id:
            missing_vars.append('TWITCH_CLIENT_ID')
        if not self.client_secret:
            missing_vars.append('TWITCH_CLIENT_SECRET')
        if not self.channel:
            missing_vars.append('TWITCH_CHANNEL')
        
        if missing_vars:
            print(f"{Fore.RED}Error: Missing required environment variables: {', '.join(missing_vars)}{Style.RESET_ALL}")
            exit(1)
            
        # Initialize the bot
        super().__init__(
            token=self.access_token,
            prefix='!',
            initial_channels=[self.channel]
        )
        self.channel_obj = None  # Will store the channel object after connection
        self.loop = asyncio.get_event_loop()

    async def event_ready(self):
        print(f"{Fore.GREEN}Connected to Twitch chat: {self.channel}{Style.RESET_ALL}")
        print(f"{Fore.YELLOW}Bot ready as {self.nick}{Style.RESET_ALL}")
        print(f"{Fore.CYAN}Type your messages below (type 'quit' or Ctrl+C to exit immediately){Style.RESET_ALL}")
        print("-" * 50)
        self.channel_obj = self.get_channel(self.channel)

    async def event_message(self, message):
        if message.echo:
            return
        timestamp = datetime.now().strftime("%H:%M:%S")
        author_color = (Fore.GREEN if message.author.is_mod else 
                       Fore.MAGENTA if message.author.is_subscriber else 
                       Fore.CYAN)
        print(f"{Fore.WHITE}[{timestamp}]{Style.RESET_ALL} "
              f"{author_color}{message.author.name}{Style.RESET_ALL}: "
              f"{message.content}")
        await self.handle_commands(message)

    async def event_token_expired(self):
        print(f"{Fore.YELLOW}Access token expired, attempting to refresh...{Style.RESET_ALL}")
        new_token = await self.refresh_access_token()
        if new_token:
            self.access_token = new_token
            return new_token
        print(f"{Fore.RED}Failed to refresh token, shutting down...{Style.RESET_ALL}")
        os._exit(1)  # Immediate exit on token refresh failure

    async def refresh_access_token(self):
        try:
            response = requests.post('https://id.twitch.tv/oauth2/token', data={
                'grant_type': 'refresh_token',
                'refresh_token': self.refresh_token,
                'client_id': self.client_id,
                'client_secret': self.client_secret
            })
            
            if response.status_code == 200:
                data = response.json()
                self.access_token = f"oauth:{data['access_token']}"
                self.refresh_token = data['refresh_token']
                os.environ['TWITCH_OAUTH_TOKEN'] = self.access_token
                os.environ['TWITCH_REFRESH_TOKEN'] = self.refresh_token
                print(f"{Fore.GREEN}Successfully refreshed access token{Style.RESET_ALL}")
                return self.access_token
            else:
                print(f"{Fore.RED}Token refresh failed: {response.text}{Style.RESET_ALL}")
                return None
        except Exception as e:
            print(f"{Fore.RED}Error refreshing token: {str(e)}{Style.RESET_ALL}")
            return None

    async def send_message(self, message):
        if not self.channel_obj:
            print(f"{Fore.RED}Error: Channel not ready{Style.RESET_ALL}")
            return
        
        try:
            await self.channel_obj.send(message)
            timestamp = datetime.now().strftime("%H:%M:%S")
            print(f"{Fore.WHITE}[{timestamp}]{Style.RESET_ALL} "
                  f"{Fore.YELLOW}[You]{Style.RESET_ALL}: {message}")
        except Exception as e:
            print(f"{Fore.RED}Error sending message: {str(e)}{Style.RESET_ALL}")

    @commands.command()
    async def ping(self, ctx):
        await ctx.send("Pong! I'm here and working.")

    @commands.command()
    async def help(self, ctx):
        await ctx.send("Available commands: !ping, !help")

async def handle_input(bot):
    while True:
        try:
            message = await aioconsole.ainput()
            if message.lower() == 'quit':
                print(f"{Fore.RED}Shutting down...{Style.RESET_ALL}")
                asyncio.ensure_future(bot.close())
                os._exit(0)  # Immediate exit
            if message.strip():
                await bot.send_message(message)
        except Exception as e:
            print(f"{Fore.RED}Error in input handler: {str(e)}{Style.RESET_ALL}")

async def main():
    print(f"{Fore.YELLOW}Starting Twitch chat bot...{Style.RESET_ALL}")
    bot = TwitchBot()
    
    # Signal handler for Ctrl+C
    def signal_handler(sig, frame):
        print(f"\n{Fore.RED}Shutting down...{Style.RESET_ALL}")
        asyncio.ensure_future(bot.close())
        os._exit(0)  # Immediate exit
    
    signal.signal(signal.SIGINT, signal_handler)
    
    try:
        # Start the bot and input handler concurrently
        bot_task = asyncio.create_task(bot.start())
        input_task = asyncio.create_task(handle_input(bot))
        
        # Wait for tasks (will exit via signal or quit)
        await asyncio.gather(bot_task, input_task, return_exceptions=True)
    except Exception as e:
        print(f"{Fore.RED}Error: {str(e)}{Style.RESET_ALL}")
        os._exit(1)  # Immediate exit on unhandled exception

if __name__ == "__main__":
    asyncio.run(main())
