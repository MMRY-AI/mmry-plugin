Run the MMRY AI setup flow. This configures the plugin using browser-based device authorization.

No credentials are entered in the terminal. The user authenticates in their browser instead.

Do NOT show the user bash commands or ask them to run anything in a terminal. You handle everything conversationally.

## Setup Flow

1. Tell the user: "I'll open your browser so you can log in to MMRY AI. If you don't have an account yet, you can create one from the sign-up page."

2. **Request a device code** from the API:
   ```
   curl -s -w '\n%{http_code}' -X POST "https://mmryai.com/api/auth/device" -H "Content-Type: application/json"
   ```
   The last line of output is the HTTP status code. The JSON body contains `deviceCode`, `verificationUrl`, `expiresIn`, and `interval`.

3. **Handle errors:**
   - Non-200: "The API is temporarily unavailable. Try again in a moment."

4. **Open the browser** to the authorization URL:
   ```
   # macOS
   open "${verificationUrl}?code=${deviceCode}"
   # Windows (Git Bash)
   cmd.exe /c start "" "${verificationUrl}?code=${deviceCode}"
   # Linux
   xdg-open "${verificationUrl}?code=${deviceCode}"
   ```
   Tell the user: "I've opened your browser. Log in (or sign up) and click 'Authorize this device'. Verify the code starts with: [first 8 chars of deviceCode]"

5. **Poll for authorization** every 2 seconds:
   ```
   curl -s -w '\n%{http_code}' "https://mmryai.com/api/auth/device/${deviceCode}/status"
   ```
   - `"status": "pending"` - Keep polling. Tell the user you're waiting.
   - `"status": "authorized"` with `apiKey` field - Success! Extract the API key.
   - `"status": "expired"` - "The authorization timed out. Let me start a new one." Start over from step 2.
   - HTTP 429 - Rate limited. Wait 5 seconds before next poll.

   **Important:** Do not poll more than once every 2 seconds. The device code expires after 10 minutes.

6. **Write the config file.** Use the Write tool to create `~/.claude/mnemo-config.json`:
   ```json
   {
     "apiUrl": "https://mmryai.com",
     "authMethod": "apikey",
     "apiKey": "THE_API_KEY"
   }
   ```

7. **Auto-approve permissions.** Read `~/.claude/settings.json`. Add these entries to the `permissions.allow` array if not already present:
   - `Bash(*save-memory.sh*)`
   - `Bash(*reinforce-memory.sh*)`
   - `Bash(*deactivate-memory.sh*)`
   - `Bash(*link-memories.sh*)`
   - `Bash(*search-memories.sh*)`
   - `Bash(*mnemo-client.sh*)`
   Write the updated file back with the Edit or Write tool. Preserve all existing settings.

8. **Tell the user:** "You're all set. Restart Claude Code and your memories will start loading automatically. Type /mnemo:help anytime for a quick reference."
