Twitch and YouTube Chat Bots

This repository contains two Python scripts for interacting with live chat on Twitch (twitchchat.py) and YouTube (youtubechat.py). Both scripts are designed to run in a terminal, ideally within a tmux pane on OpenBSD, and provide features like reading chat messages, sending messages, and immediate shutdown.

-------------------------------------------------------------------------------

Features

- Twitch Chat Bot (twitchchat.py):
  - Reads live Twitch chat with color-coded output (moderators green, subscribers magenta, others cyan)
  - Sends messages via terminal input
  - Automatically refreshes OAuth token when expired
  - Supports basic commands (!ping, !help)
  - Immediate exit with Ctrl+C or quit

- YouTube Chat Bot (youtubechat.py):
  - Polls YouTube live chat with color-coded output (moderators green, verified users magenta, others cyan)
  - Sends messages via terminal input
  - Clears screen after successful authentication
  - Immediate exit with Ctrl+C or quit

-------------------------------------------------------------------------------

Prerequisites

- Operating System: Tested on OpenBSD; should work on other Unix-like systems
- Python: Version 3.12 or later
- tmux: For running in a terminal pane (optional but recommended)
- Internet Connection: Required for API access

-------------------------------------------------------------------------------

Installation

Step 1: Install Dependencies

1. Install Python and pip:
   Run: pkg_add python-3.12 py3-pip

2. Install Python Packages:
   - For both scripts:
     Run: pip3.12 install colorama aioconsole requests
   - For twitchchat.py:
     Run: pip3.12 install twitchio
   - For youtubechat.py:
     Run: pip3.12 install google-api-python-client google-auth-oauthlib

Step 2: Obtain API Keys

Twitch API Keys

1. Create a Twitch Developer Application:
   - Go to: https://dev.twitch.tv/console
   - Log in with your Twitch account
   - Click "Register Your Application"
   - Fill in:
     - Name: e.g., TwitchChatBot
     - OAuth Redirect URLs: http://localhost
     - Category: Chat Bot
   - Click "Create"
   - Click "Manage" on your application
   - Note your Client ID and generate a Client Secret

2. Get OAuth Tokens:
   - Use a tool like https://twitchtokengenerator.com/ or manually:
     - Visit: https://id.twitch.tv/oauth2/authorize?client_id=YOUR_CLIENT_ID&redirect_uri=http://localhost&response_type=token&scope=chat:read+chat:edit
     - Log in and authorize
     - Extract access_token from the redirected URL (e.g., http://localhost/#access_token=your_access_token&...)
   - For full OAuth with refresh token:
     - Use curl:
       Run: curl -X POST 'https://id.twitch.tv/oauth2/token' \
            -d 'client_id=YOUR_CLIENT_ID' \
            -d 'client_secret=YOUR_CLIENT_SECRET' \
            -d 'grant_type=authorization_code' \
            -d 'redirect_uri=http://localhost' \
            -d 'code=CODE_FROM_AUTH_URL'
     - Replace CODE_FROM_AUTH_URL with the code from the redirect after authorizing

YouTube API Keys

1. Create a Google Cloud Project:
   - Go to: https://console.cloud.google.com/
   - Click "New Project" and name it (e.g., YouTubeChatBot)
   - Select the project

2. Enable YouTube Data API:
   - Navigate to "APIs & Services" > "Library"
   - Search for "YouTube Data API v3"
   - Click "Enable"

3. Create OAuth 2.0 Credentials:
   - Go to "Credentials" > "Create Credentials" > "OAuth 2.0 Client IDs"
   - Application type: Desktop app
   - Name: e.g., YouTube Chat Client
   - Click "Create"
   - Download the JSON file as client_secrets.json and place it in the script directory

4. Get Your Channel ID:
   - Go to: https://studio.youtube.com/
   - Click "Settings" > "Channel" > "Advanced Settings"
   - Copy your Channel ID (e.g., UCxxxxxxxxxxxxxxxxxxxxxx)

Step 3: Configure Environment Variables

Create or edit a tokens.sh file in the script directory:

#!/bin/sh
# Twitch credentials
export TWITCH_OAUTH_TOKEN='oauth:your_access_token'
export TWITCH_REFRESH_TOKEN='your_refresh_token'
export TWITCH_CLIENT_ID='your_client_id'
export TWITCH_CLIENT_SECRET='your_client_secret'
export TWITCH_CHANNEL='yourchannelname'  # e.g., 'yourusername'

# YouTube credentials
export YOUTUBE_CLIENT_SECRET_FILE='client_secrets.json'
export YOUTUBE_CHANNEL_ID='your_channel_id'  # e.g., 'UCxxxxxxxxxxxxxxxxxxxxxx'

Source the file:
Run: . ./tokens.sh

-------------------------------------------------------------------------------

Usage

Running in tmux

1. Start a tmux Session:
   Run: tmux new -s chat

2. Run Twitch Chat:
   Run: python3.12 twitchchat.py
   - Connects to Twitch chat
   - Type messages to send
   - Exit with Ctrl+C or quit

3. Run YouTube Chat:
   Run: python3.12 youtubechat.py
   - Authenticates via browser (first run)
   - Clears screen after connecting
   - Type messages to send
   - Exit with Ctrl+C or quit

4. Split Panes (Optional):
   - Horizontal split: Ctrl-b "
   - Vertical split: Ctrl-b %
   - Run both scripts in separate panes

5. Detach from tmux:
   - Ctrl-b d

Example Output

Twitch:
Starting Twitch chat bot...
Connected to Twitch chat: yourchannelname
Bot ready as yourbotname
Type your messages below (type 'quit' or Ctrl+C to exit immediately)
--------------------------------------------------
[12:34:56] user1: Hello world!
[12:34:58] [You]: Hi there!

YouTube:
Starting YouTube chat bot...
[Browser authentication prompt]
Connected to YouTube live chat
Type your messages below (type 'quit' or Ctrl+C to exit immediately)
--------------------------------------------------
[12:34:56] UserOne: Great stream!
[12:34:58] [You]: Thanks!

-------------------------------------------------------------------------------

Troubleshooting

General
- Dependency Errors:
  Run: pip3.12 install --user <package>
- Network Issues:
  Run: ping irc.chat.twitch.tv  # For Twitch
  Run: ping www.googleapis.com   # For YouTube

Twitch
- Invalid Token:
  Verify with:
  Run: curl -H "Authorization: Bearer ${TWITCH_OAUTH_TOKEN#oauth:}" \
       https://id.twitch.tv/oauth2/validate
  - Refresh token manually if needed

YouTube
- No Live Chat Found:
  - Ensure a live stream is active on your channel
- API Quota Exceeded:
  - Check usage in Google Cloud Console under "APIs & Services" > "Dashboard"
  - Default quota: 10,000 units/day (polling ~1 unit/call)

-------------------------------------------------------------------------------

Notes

- Twitch: Uses real-time IRC connection; requires valid OAuth tokens
- YouTube: Polls API (5-10s delay); requires active live stream and OAuth 2.0
- Immediate Exit: Both scripts exit instantly with Ctrl+C or quit using os._exit()

-------------------------------------------------------------------------------

License

This project is unlicensed—feel free to use, modify, and distribute as you see fit!
