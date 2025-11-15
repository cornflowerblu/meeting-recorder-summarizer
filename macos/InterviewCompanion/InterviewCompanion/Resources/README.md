# Firebase Configuration

## Setup Instructions

1. Go to https://console.firebase.google.com
2. Select your project (or create a new one)
3. Click **gear icon** ⚙️ → **Project Settings**
4. Scroll down to "Your apps"
5. Click **iOS** button (macOS uses iOS SDK)
6. Register your app:
   - Bundle ID: `com.slingshotgroup.interviewcompanion`
   - App nickname: "Interview Companion"
7. Download `GoogleService-Info.plist`
8. **Place the file in this directory**: `macos/Sources/MeetingRecorder/Resources/`
9. The file should be named exactly: `GoogleService-Info.plist`

## Firebase Authentication Setup

After adding the plist file, enable authentication in Firebase Console:

1. Go to **Authentication** in Firebase Console sidebar
2. Click **Get Started**
3. Enable **Email/Password** sign-in method
4. Optionally enable **Google** sign-in for OAuth

## Verify Setup

The app will automatically load the configuration from `GoogleService-Info.plist` on launch.

If you see an error about Firebase not being configured, check that:
- The plist file is in this directory
- The file is named exactly `GoogleService-Info.plist`
- The Swift package has been rebuilt (`swift build`)
