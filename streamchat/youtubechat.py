#!/usr/bin/env python3

import asyncio
import os
import signal
import time
from datetime import datetime
import colorama
from colorama import Fore, Style
import aioconsole
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

# Initialize colorama for colored terminal output
colorama.init()

# YouTube API scopes
SCOPES = ["https://www.googleapis.com/auth/youtube.force-ssl"]

def clear_screen():
    """Clear the terminal screen in a cross-platform way"""
    os.system('cls' if os.name == 'nt' else 'clear')

class YouTubeChatBot:
    def __init__(self):
        # Get credentials from environment variables
        self.client_secret_file = os.getenv('YOUTUBE_CLIENT_SECRET_FILE', 'client_secrets.json')
        self.channel_id = os.getenv('YOUTUBE_CHANNEL_ID')
        self.live_chat_id = None
        
        # Check for missing variables
        if not self.channel_id:
            print(f"{Fore.RED}Error: Missing YOUTUBE_CHANNEL_ID environment variable{Style.RESET_ALL}")
            exit(1)
        if not os.path.exists(self.client_secret_file):
            print(f"{Fore.RED}Error: Client secret file {self.client_secret_file} not found{Style.RESET_ALL}")
            exit(1)
        
        # Authenticate and build YouTube API client
        self.youtube = self.authenticate()
        self.live_chat_id = self.wait_for_live_chat()

    def authenticate(self):
        """Authenticate with YouTube API using OAuth 2.0"""
        print(f"{Fore.YELLOW}Authenticating with YouTube API...{Style.RESET_ALL}")
        flow = InstalledAppFlow.from_client_secrets_file(self.client_secret_file, SCOPES)
        credentials = flow.run_local_server(port=0)
        return build('youtube', 'v3', credentials=credentials)

    def get_live_chat_id(self):
        """Get the live chat ID for the current live broadcast"""
        try:
            request = self.youtube.liveBroadcasts().list(
                part="id,snippet",
                broadcastStatus="active",
                broadcastType="all"
            )
            response = request.execute()
            for item in response.get('items', []):
                if item['snippet']['channelId'] == self.channel_id:
                    return item['snippet']['liveChatId']
            return None
        except HttpError as e:
            print(f"{Fore.RED}Error fetching live chat ID: {str(e)}{Style.RESET_ALL}")
            return None

    def wait_for_live_chat(self):
        """Poll until an active live chat is found"""
        print(f"{Fore.YELLOW}Waiting for an active live chat...{Style.RESET_ALL}")
        while True:
            live_chat_id = self.get_live_chat_id()
            if live_chat_id:
                clear_screen()  # Clear screen when live chat is found
                print(f"{Fore.GREEN}Live chat found! Connected to YouTube live chat{Style.RESET_ALL}")
                return live_chat_id
            print(f"{Fore.YELLOW}No active live chat found. Retrying in 10 seconds...{Style.RESET_ALL}")
            time.sleep(10)  # Poll every 10 seconds

    async def fetch_messages(self, last_message_id=None):
        """Fetch new messages from the live chat"""
        try:
            request = self.youtube.liveChatMessages().list(
                liveChatId=self.live_chat_id,
                part="id,snippet,authorDetails",
                maxResults=200,
                pageToken=None if not last_message_id else None
            )
            response = request.execute()
            messages = response.get('items', [])
            next_page_token = response.get('nextPageToken')
            polling_interval = response.get('pollingIntervalMillis', 5000) / 1000  # Convert to seconds
            return messages, next_page_token, polling_interval
        except HttpError as e:
            print(f"{Fore.RED}Error fetching messages: {str(e)}{Style.RESET_ALL}")
            return [], None, 5  # Default 5-second polling on error

    async def send_message(self, message):
        """Send a message to the live chat"""
        try:
            request = self.youtube.liveChatMessages().insert(
                part="snippet",
                body={
                    "snippet": {
                        "liveChatId": self.live_chat_id,
                        "type": "textMessageEvent",
                        "textMessageDetails": {
                            "messageText": message
                        }
                    }
                }
            )
            response = request.execute()
            timestamp = datetime.now().strftime("%H:%M:%S")
            print(f"{Fore.WHITE}[{timestamp}]{Style.RESET_ALL} "
                  f"{Fore.YELLOW}[You]{Style.RESET_ALL}: {message}")
        except HttpError as e:
            print(f"{Fore.RED}Error sending message: {str(e)}{Style.RESET_ALL}")

async def poll_chat(bot):
    """Poll the live chat for new messages"""
    last_message_id = None
    while True:
        messages, next_page_token, polling_interval = await bot.fetch_messages(last_message_id)
        for message in messages:
            msg_id = message['id']
            if last_message_id and msg_id <= last_message_id:
                continue
            last_message_id = msg_id
            snippet = message['snippet']
            author = message['authorDetails']
            timestamp = datetime.strptime(snippet['publishedAt'], "%Y-%m-%dT%H:%M:%S.%fZ").strftime("%H:%M:%S")
            author_color = (Fore.GREEN if author['isChatModerator'] else 
                          Fore.MAGENTA if author.get('isVerified', False) else 
                          Fore.CYAN)
            print(f"{Fore.WHITE}[{timestamp}]{Style.RESET_ALL} "
                  f"{author_color}{author['displayName']}{Style.RESET_ALL}: "
                  f"{snippet['displayMessage']}")
        await asyncio.sleep(polling_interval)

async def handle_input(bot):
    """Handle user input to send messages"""
    while True:
        try:
            message = await aioconsole.ainput()
            if message.lower() == 'quit':
                print(f"{Fore.RED}Shutting down...{Style.RESET_ALL}")
                os._exit(0)  # Immediate exit
            if message.strip():
                await bot.send_message(message)
        except Exception as e:
            print(f"{Fore.RED}Error in input handler: {str(e)}{Style.RESET_ALL}")

async def main():
    print(f"{Fore.YELLOW}Starting YouTube chat bot...{Style.RESET_ALL}")
    bot = YouTubeChatBot()
    
    # Signal handler for Ctrl+C
    def signal_handler(sig, frame):
        print(f"\n{Fore.RED}Shutting down...{Style.RESET_ALL}")
        os._exit(0)  # Immediate exit
    
    signal.signal(signal.SIGINT, signal_handler)
    
    print(f"{Fore.CYAN}Type your messages below (type 'quit' or Ctrl+C to exit immediately){Style.RESET_ALL}")
    print("-" * 50)
    
    try:
        # Start chat polling and input handling concurrently
        chat_task = asyncio.create_task(poll_chat(bot))
        input_task = asyncio.create_task(handle_input(bot))
        
        # Wait for tasks (will exit via signal or quit)
        await asyncio.gather(chat_task, input_task, return_exceptions=True)
    except Exception as e:
        print(f"{Fore.RED}Error: {str(e)}{Style.RESET_ALL}")
        os._exit(1)  # Immediate exit on unhandled exception

if __name__ == "__main__":
    asyncio.run(main())
