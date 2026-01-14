# RapidReport SaaS - Production Deployment Guide

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         FRONTEND                                 │
│  (index.html - Netlify/Vercel)                                  │
│  • Supabase Auth (Google, Apple, Email)                         │
│  • Stripe Checkout                                               │
│  • Full Application UI                                           │
└──────────────────────┬──────────────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┐
        ▼                              ▼
┌───────────────────┐      ┌─────────────────────┐
│   SUPABASE        │      │   BACKEND API       │
│   • Auth          │      │   (Railway/Render)  │
│   • Database      │      │   • Stripe Webhooks │
│   • Row Security  │      │   • Subscription    │
└───────────────────┘      └─────────────────────┘
                                    │
                                    ▼
                           ┌───────────────────┐
                           │      STRIPE       │
                           │   • Payments      │
                           │   • Subscriptions │
                           │   • Portal        │
                           └───────────────────┘
```

## ✅ Features

- **Real Authentication** - Supabase Auth (email, Google, Apple)
- **Password Reset** - Secure email-based flow
- **7-Day Free Trial** - Credit card required
- **€19.99/month** - Automatic billing via Stripe
- **Subscription States** - trialing, active, past_due, canceled
- **Access Control** - Backend + Frontend enforcement
- **Customer Portal** - Manage payment, cancel subscription
- **Subscription Status** - Clear visibility in settings
- **Account Deletion** - GDPR compliant, one-click delete
- **Email Notifications** - Via Stripe (payment success/failure/canceled)

---

## 📦 Files Included

| File | Description |
|------|-------------|
| `index.html` | Complete frontend application |
| `api/server.js` | Backend API (Express.js) |
| `supabase-schema.sql` | Database schema with RLS |
| `package.json` | Node.js dependencies |
| `.env.example` | Environment variables template |

---

## 🚀 Deployment Steps

### Step 1: Create Supabase Project

1. Go to [supabase.com](https://supabase.com) → New Project
2. Save your project credentials:
   - **Project URL** → `SUPABASE_URL`
   - **anon public key** → `SUPABASE_ANON_KEY`  
   - **service_role key** → `SUPABASE_SERVICE_ROLE_KEY`

3. Run the database schema:
   - Go to **SQL Editor**
   - Paste contents of `supabase-schema.sql`
   - Click **Run**

4. Enable Authentication Providers:
   - Go to **Authentication → Providers**
   - Enable **Email** (turn on email confirmations)
   - Enable **Google** (see Google OAuth below)
   - Enable **Apple** (see Apple Sign-In below)

### Step 2: Configure Google OAuth

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create new project or select existing
3. Go to **APIs & Services → Credentials**
4. Create **OAuth 2.0 Client ID**:
   - Application type: **Web application**
   - Authorized redirect URI: `https://YOUR_PROJECT.supabase.co/auth/v1/callback`
5. Copy **Client ID** and **Client Secret** to Supabase → Authentication → Providers → Google

### Step 3: Configure Apple Sign-In

1. Go to [developer.apple.com](https://developer.apple.com)
2. Create **Services ID** for Sign In with Apple
3. Add redirect URL: `https://YOUR_PROJECT.supabase.co/auth/v1/callback`
4. Generate key and copy to Supabase → Authentication → Providers → Apple

### Step 4: Create Stripe Account & Product

1. Go to [stripe.com](https://stripe.com) → Create account
2. Create Product:
   - Go to **Products → Add Product**
   - Name: `RapidReport Professional`
   - Price: `€19.99` recurring monthly
   - Copy **Price ID** → `STRIPE_PRICE_ID`

3. Get API Keys:
   - Go to **Developers → API Keys**
   - Copy **Publishable key** → `STRIPE_PUBLISHABLE_KEY`
   - Copy **Secret key** → `STRIPE_SECRET_KEY`

4. Configure Customer Portal:
   - Go to **Settings → Billing → Customer portal**
   - Enable: Update payment methods, Cancel subscription
   - Save

5. Configure Email Notifications (IMPORTANT):
   - Go to **Settings → Emails**
   - Enable:
     - ✅ Successful payments
     - ✅ Failed payments  
     - ✅ Upcoming renewals
     - ✅ Subscription canceled
     - ✅ Trial ending soon
   - This ensures users receive all required notifications automatically

### Step 5: Deploy Backend API

#### Option A: Railway (Recommended)

```bash
# Install Railway CLI
npm install -g @railway/cli

# Login
railway login

# Initialize project
cd rapidreport-saas
railway init

# Add environment variables
railway variables set SUPABASE_URL=xxx
railway variables set SUPABASE_SERVICE_ROLE_KEY=xxx
railway variables set STRIPE_SECRET_KEY=xxx
railway variables set STRIPE_WEBHOOK_SECRET=xxx
railway variables set STRIPE_PRICE_ID=xxx
railway variables set FRONTEND_URL=https://your-app.netlify.app

# Deploy
railway up
```

#### Option B: Render

1. Connect GitHub repo to [render.com](https://render.com)
2. Create **Web Service**
3. Set environment variables
4. Deploy

### Step 6: Configure Stripe Webhooks

1. Go to Stripe → **Developers → Webhooks**
2. Add endpoint: `https://YOUR_API_URL/api/webhooks/stripe`
3. Select events:
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.payment_succeeded`
   - `invoice.payment_failed`
   - `customer.subscription.trial_will_end`
4. Copy **Signing secret** → `STRIPE_WEBHOOK_SECRET`

### Step 7: Deploy Frontend

1. Edit `index.html` - Replace CONFIG values (around line 297):

```javascript
const CONFIG = {
  SUPABASE_URL: 'https://xxx.supabase.co',
  SUPABASE_ANON_KEY: 'eyJ...',
  API_URL: 'https://your-api.railway.app',
  STRIPE_PUBLISHABLE_KEY: 'pk_live_...'
};
```

2. Deploy to Netlify:
   - Go to [app.netlify.com/drop](https://app.netlify.com/drop)
   - Drag & drop the **entire folder** (not just index.html)
   - Done!

**Important:** The folder includes:
- `netlify.toml` - SPA routing configuration
- `_redirects` - Fallback routing rules
- `index.html` - Your application

**If you see "Configuration Required" page:** The app detected placeholder values in CONFIG. Edit index.html and redeploy.

---

## 🔐 Security Checklist

- [ ] RLS enabled on all Supabase tables ✅ (done in schema)
- [ ] `service_role` key only on backend
- [ ] `STRIPE_SECRET_KEY` never exposed to frontend
- [ ] Webhook signature verification enabled
- [ ] HTTPS everywhere
- [ ] Email confirmation enabled

---

## 📧 Email Notifications (via Stripe)

| Event | Email Sent | Configuration |
|-------|------------|---------------|
| Trial started | ✅ | Stripe Settings → Emails |
| Trial ending (3 days) | ✅ | Stripe Settings → Emails |
| Payment successful | ✅ | Stripe Settings → Emails |
| Payment failed | ✅ | Stripe Settings → Emails |
| Subscription canceled | ✅ | Stripe Settings → Emails |
| Account created | ✅ | Supabase Auth → Email Templates |
| Password reset | ✅ | Supabase Auth → Email Templates |

---

## ⚖️ GDPR Compliance

| Requirement | Implementation |
|-------------|----------------|
| Right to access | User can view all data in app |
| Right to rectification | User can edit profile/company |
| Right to erasure | DELETE `/api/account` endpoint |
| Data portability | Export reports as PDF |
| Consent | Stripe handles payment consent |

---

## 💳 Subscription Flow

| State | Access | Action Required |
|-------|--------|-----------------|
| `trialing` | ✅ Full | None |
| `active` | ✅ Full | None |
| `past_due` | ❌ Restricted | Update payment |
| `canceled` | ❌ None | Resubscribe |

### When Trial Expires
- User redirected to Subscribe page
- Clear message explaining why
- Stripe Checkout button

### Payment Failure
- Banner shown in app
- Direct link to update payment
- Stripe handles retries automatically

---

## 🧪 Testing

### Test Mode
Use Stripe **test keys** (prefixed with `sk_test_` and `pk_test_`).

### Test Card Numbers
- ✅ Success: `4242 4242 4242 4242`
- ❌ Decline: `4000 0000 0000 0002`
- 🔐 3D Secure: `4000 0027 6000 3184`

### Local Webhook Testing
```bash
# Install Stripe CLI
brew install stripe/stripe-cli/stripe

# Listen to webhooks
stripe listen --forward-to localhost:3000/api/webhooks/stripe
```

---

## 📞 API Endpoints

| Method | Endpoint | Auth | Subscription | Description |
|--------|----------|------|--------------|-------------|
| GET | `/api/health` | ❌ | ❌ | Health check |
| GET | `/api/subscription` | ✅ | ❌ | Get subscription status |
| POST | `/api/create-checkout-session` | ✅ | ❌ | Start Stripe checkout |
| POST | `/api/create-portal-session` | ✅ | ❌ | Open billing portal |
| POST | `/api/webhooks/stripe` | ❌ | ❌ | Stripe webhook handler |
| DELETE | `/api/account` | ✅ | ❌ | Delete account (GDPR) |

---

## 🆘 Troubleshooting

### Netlify Deployment Issues

| Problem | Solution |
|---------|----------|
| "Configuration Required" page | Edit CONFIG in index.html, replace YOUR_xxx values |
| 404 on page refresh | Make sure netlify.toml and _redirects are deployed |
| Blank page | Check browser console for JavaScript errors |
| "Page Not Found" | Deploy the entire folder, not just index.html |

### "Invalid token" error
- Check Supabase project URL is correct
- Ensure user is logged in

### Webhook not working
- Verify endpoint URL is correct
- Check webhook signing secret
- Look at Stripe Dashboard → Webhooks → Recent events

### Google/Apple login not working
- Verify redirect URLs match exactly
- Check credentials in Supabase dashboard

### Subscription not updating
- Check webhook events in Stripe Dashboard
- Verify API server is running
- Check API logs for errors

---

## 📄 License

Built with ❤️ for professional inspections.
