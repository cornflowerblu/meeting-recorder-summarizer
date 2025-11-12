# Firebase Setup Guide

Step-by-step guide to configure Firebase Authentication with Google Workspace for Meeting Recorder.

## Prerequisites

- Google Workspace account
- Access to [Firebase Console](https://console.firebase.google.com)
- Browser with access to your Google Workspace account

## Step 1: Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Click **"Add project"** or **"Create a project"**
3. Enter project name: `meeting-recorder` (or your preferred name)
4. Disable Google Analytics (optional for this project)
5. Click **"Create project"**

## Step 2: Enable Google Sign-In

1. In Firebase Console, navigate to **Build > Authentication**
2. Click **"Get Started"**
3. Go to **"Sign-in method"** tab
4. Click on **"Google"**
5. Toggle **"Enable"**
6. Under **"Web SDK configuration"**:
   - Select your Google Workspace domain
   - **Public-facing name**: "Meeting Recorder"
   - **Support email**: Your Google Workspace email
7. Click **"Save"**

## Step 3: Configure Authorized Domains

1. In Authentication section, go to **"Settings"** tab
2. Scroll to **"Authorized domains"**
3. The following should already be listed:
   - `localhost` (for development)
   - Your Firebase hosting domain (if applicable)
4. Add any additional domains where your app will run

## Step 4: Get Firebase Configuration

### Project Settings
1. Click **⚙️ (Settings icon)** → **"Project settings"**
2. Note down:
   - **Project ID**: `your-project-id` (needed for Terraform)
   - **Web API Key**: (if needed for direct API access)

### Service Account for AWS Integration
1. Still in **Project settings**, go to **"Service accounts"** tab
2. Click **"Generate new private key"**
3. Save the JSON file securely (contains credentials)
4. Note the **OAuth 2.0 Client ID** (format: `project-id@*.iam.gserviceaccount.com`)

## Step 5: Configure Google Cloud Identity Platform

Firebase Authentication uses Google Cloud Identity Platform. We need to set up the OIDC provider for AWS.

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Select your Firebase project
3. Navigate to **APIs & Services > Credentials**
4. The OAuth 2.0 client should be auto-created by Firebase
5. Note the **Client ID** for the web application

## Step 6: Test Google Sign-In (Optional)

You can test authentication using Firebase's built-in tester:

1. In Firebase Console → Authentication
2. Go to **"Users"** tab
3. Click **"Add user"** to manually add test users
4. Or use the Firebase Auth Emulator for local testing

## Configuration Values for Terraform

After completing the above steps, you'll need these values for `terraform.tfvars`:

```hcl
# Firebase Configuration
firebase_project_id = "your-firebase-project-id"  # From Step 4
```

## AWS Integration (Handled by Terraform)

The Terraform configuration will automatically:
1. Create an OIDC identity provider in AWS IAM
2. Configure trust relationship for Firebase tokens
3. Set up the IAM role for macOS app

The OIDC provider URL will be:
```
https://securetoken.google.com/YOUR_FIREBASE_PROJECT_ID
```

## Verification

After setup, you should have:
- ✅ Firebase project created
- ✅ Google Sign-In enabled
- ✅ Project ID noted
- ✅ Web API Key available
- ✅ Service account created (optional)

## Next Steps

1. Update `terraform.tfvars` with Firebase project ID
2. Run `terraform apply` to create AWS resources
3. The auth exchange Lambda will be configured automatically
4. Test authentication flow from macOS app

## Troubleshooting

### Issue: "Unauthorized domain"
- Add your domain to Firebase authorized domains
- For local development, ensure `localhost` is listed

### Issue: "Invalid ID token"
- Check that Firebase project ID matches in both Firebase and AWS
- Verify OIDC provider is correctly configured in AWS
- Ensure token hasn't expired (1 hour lifetime)

### Issue: "Access denied"
- Check IAM role trust policy includes correct Firebase OIDC provider
- Verify audience (`aud`) claim in token matches Firebase project ID

## Security Notes

- ✅ Never commit service account JSON files to git
- ✅ Use environment variables for sensitive config
- ✅ Rotate service account keys regularly
- ✅ Use least-privilege IAM policies
- ✅ Monitor authentication logs in Firebase Console

---

**Next**: [Terraform Deployment](./terraform-deployment.md)
