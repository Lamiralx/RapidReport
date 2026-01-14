// ============================================
// RAPIDREPORT SAAS - BACKEND SERVER
// Production-ready with Stripe & Supabase
// ============================================

import express from 'express';
import Stripe from 'stripe';
import { createClient } from '@supabase/supabase-js';
import cors from 'cors';
import dotenv from 'dotenv';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Initialize Stripe
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY, {
  apiVersion: '2023-10-16'
});

// Initialize Supabase Admin Client
const supabaseAdmin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

// CORS configuration
app.use(cors({
  origin: process.env.FRONTEND_URL || 'http://localhost:5173',
  credentials: true
}));

// Stripe webhook endpoint - raw body needed
app.post('/api/webhooks/stripe', express.raw({ type: 'application/json' }), async (req, res) => {
  const sig = req.headers['stripe-signature'];
  let event;

  try {
    event = stripe.webhooks.constructEvent(
      req.body,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  try {
    switch (event.type) {
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
        await handleSubscriptionUpdate(event.data.object);
        break;
      
      case 'customer.subscription.deleted':
        await handleSubscriptionDeleted(event.data.object);
        break;
      
      case 'invoice.payment_succeeded':
        await handlePaymentSucceeded(event.data.object);
        break;
      
      case 'invoice.payment_failed':
        await handlePaymentFailed(event.data.object);
        break;
      
      case 'customer.subscription.trial_will_end':
        await handleTrialWillEnd(event.data.object);
        break;
      
      default:
        console.log(`Unhandled event type: ${event.type}`);
    }

    res.json({ received: true });
  } catch (err) {
    console.error('Webhook handler error:', err);
    res.status(500).send('Webhook handler error');
  }
});

// JSON parsing for other routes
app.use(express.json());

// ============================================
// SUBSCRIPTION HANDLERS
// ============================================

async function handleSubscriptionUpdate(subscription) {
  const { customer, status, current_period_end, trial_end } = subscription;
  
  // Get user by Stripe customer ID
  const { data: profile, error } = await supabaseAdmin
    .from('profiles')
    .select('id')
    .eq('stripe_customer_id', customer)
    .single();

  if (error || !profile) {
    console.error('User not found for customer:', customer);
    return;
  }

  // Update subscription status in database
  await supabaseAdmin
    .from('subscriptions')
    .upsert({
      user_id: profile.id,
      stripe_subscription_id: subscription.id,
      stripe_customer_id: customer,
      status: status,
      current_period_end: new Date(current_period_end * 1000).toISOString(),
      trial_end: trial_end ? new Date(trial_end * 1000).toISOString() : null,
      cancel_at_period_end: subscription.cancel_at_period_end,
      updated_at: new Date().toISOString()
    }, {
      onConflict: 'user_id'
    });

  console.log(`Subscription updated for user ${profile.id}: ${status}`);
}

async function handleSubscriptionDeleted(subscription) {
  const { customer } = subscription;
  
  const { data: profile } = await supabaseAdmin
    .from('profiles')
    .select('id')
    .eq('stripe_customer_id', customer)
    .single();

  if (!profile) return;

  await supabaseAdmin
    .from('subscriptions')
    .update({
      status: 'canceled',
      updated_at: new Date().toISOString()
    })
    .eq('user_id', profile.id);

  console.log(`Subscription canceled for user ${profile.id}`);
}

async function handlePaymentSucceeded(invoice) {
  if (invoice.billing_reason === 'subscription_create') {
    console.log('Initial subscription payment succeeded');
  }
}

async function handlePaymentFailed(invoice) {
  const { customer, subscription } = invoice;
  
  const { data: profile } = await supabaseAdmin
    .from('profiles')
    .select('id, email')
    .eq('stripe_customer_id', customer)
    .single();

  if (!profile) return;

  // Update subscription to past_due
  await supabaseAdmin
    .from('subscriptions')
    .update({
      status: 'past_due',
      payment_failed_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    })
    .eq('user_id', profile.id);

  console.log(`Payment failed for user ${profile.id}`);
}

async function handleTrialWillEnd(subscription) {
  const { customer } = subscription;
  
  const { data: profile } = await supabaseAdmin
    .from('profiles')
    .select('id, email')
    .eq('stripe_customer_id', customer)
    .single();

  if (!profile) return;
  
  console.log(`Trial ending soon for user ${profile.id}`);
  // Could trigger email notification here
}

// ============================================
// API ROUTES
// ============================================

// Middleware to verify Supabase JWT
async function authenticateUser(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const token = authHeader.split(' ')[1];
  
  try {
    const { data: { user }, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !user) {
      return res.status(401).json({ error: 'Invalid token' });
    }
    req.user = user;
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Authentication failed' });
  }
}

// Middleware to check subscription status
async function requireActiveSubscription(req, res, next) {
  const { data: subscription } = await supabaseAdmin
    .from('subscriptions')
    .select('*')
    .eq('user_id', req.user.id)
    .single();

  if (!subscription) {
    return res.status(403).json({ 
      error: 'No subscription found',
      code: 'NO_SUBSCRIPTION'
    });
  }

  const validStatuses = ['active', 'trialing'];
  if (!validStatuses.includes(subscription.status)) {
    return res.status(403).json({ 
      error: 'Subscription not active',
      code: 'SUBSCRIPTION_INACTIVE',
      status: subscription.status
    });
  }

  req.subscription = subscription;
  next();
}

// Create Stripe Checkout Session
app.post('/api/create-checkout-session', authenticateUser, async (req, res) => {
  try {
    const user = req.user;
    
    // Get or create Stripe customer
    let { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('stripe_customer_id')
      .eq('id', user.id)
      .single();

    let customerId = profile?.stripe_customer_id;

    if (!customerId) {
      // Create new Stripe customer
      const customer = await stripe.customers.create({
        email: user.email,
        metadata: {
          supabase_user_id: user.id
        }
      });
      customerId = customer.id;

      // Save customer ID to profile
      await supabaseAdmin
        .from('profiles')
        .update({ stripe_customer_id: customerId })
        .eq('id', user.id);
    }

    // Create checkout session with 7-day trial
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      payment_method_types: ['card'],
      mode: 'subscription',
      line_items: [{
        price: process.env.STRIPE_PRICE_ID, // €19.99/month price ID
        quantity: 1
      }],
      subscription_data: {
        trial_period_days: 7,
        metadata: {
          user_id: user.id
        }
      },
      success_url: `${process.env.FRONTEND_URL}/subscription/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${process.env.FRONTEND_URL}/subscription/cancel`,
      allow_promotion_codes: true
    });

    res.json({ sessionId: session.id, url: session.url });
  } catch (err) {
    console.error('Checkout session error:', err);
    res.status(500).json({ error: 'Failed to create checkout session' });
  }
});

// Create Stripe Customer Portal Session
app.post('/api/create-portal-session', authenticateUser, async (req, res) => {
  try {
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('stripe_customer_id')
      .eq('id', req.user.id)
      .single();

    if (!profile?.stripe_customer_id) {
      return res.status(400).json({ error: 'No billing account found' });
    }

    const session = await stripe.billingPortal.sessions.create({
      customer: profile.stripe_customer_id,
      return_url: `${process.env.FRONTEND_URL}/settings`
    });

    res.json({ url: session.url });
  } catch (err) {
    console.error('Portal session error:', err);
    res.status(500).json({ error: 'Failed to create portal session' });
  }
});

// Get subscription status
app.get('/api/subscription', authenticateUser, async (req, res) => {
  try {
    const { data: subscription } = await supabaseAdmin
      .from('subscriptions')
      .select('*')
      .eq('user_id', req.user.id)
      .single();

    if (!subscription) {
      return res.json({ 
        status: 'none',
        hasAccess: false,
        needsSubscription: true
      });
    }

    const hasAccess = ['active', 'trialing'].includes(subscription.status);
    const isTrialing = subscription.status === 'trialing';
    const trialEndsAt = subscription.trial_end;
    const isPastDue = subscription.status === 'past_due';

    res.json({
      status: subscription.status,
      hasAccess,
      isTrialing,
      trialEndsAt,
      isPastDue,
      currentPeriodEnd: subscription.current_period_end,
      cancelAtPeriodEnd: subscription.cancel_at_period_end
    });
  } catch (err) {
    console.error('Get subscription error:', err);
    res.status(500).json({ error: 'Failed to get subscription' });
  }
});

// Protected endpoint example - Create Report
app.post('/api/reports', authenticateUser, requireActiveSubscription, async (req, res) => {
  // Only accessible with active subscription
  const { title, templateId, data } = req.body;
  
  const { data: report, error } = await supabaseAdmin
    .from('reports')
    .insert({
      user_id: req.user.id,
      title,
      template_id: templateId,
      data,
      created_at: new Date().toISOString()
    })
    .select()
    .single();

  if (error) {
    return res.status(500).json({ error: 'Failed to create report' });
  }

  res.json(report);
});

// Get reports (read-only allowed even without subscription)
app.get('/api/reports', authenticateUser, async (req, res) => {
  const { data: reports, error } = await supabaseAdmin
    .from('reports')
    .select('*')
    .eq('user_id', req.user.id)
    .order('created_at', { ascending: false });

  if (error) {
    return res.status(500).json({ error: 'Failed to get reports' });
  }

  res.json(reports);
});

// Generate PDF (requires active subscription)
app.post('/api/reports/:id/pdf', authenticateUser, requireActiveSubscription, async (req, res) => {
  const { id } = req.params;
  
  // Verify report belongs to user
  const { data: report, error } = await supabaseAdmin
    .from('reports')
    .select('*')
    .eq('id', id)
    .eq('user_id', req.user.id)
    .single();

  if (error || !report) {
    return res.status(404).json({ error: 'Report not found' });
  }

  // PDF generation allowed
  res.json({ allowed: true, report });
});

// Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Delete account (GDPR compliance)
app.delete('/api/account', authenticateUser, async (req, res) => {
  try {
    const userId = req.user.id;

    // 1. Cancel Stripe subscription if exists
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('stripe_customer_id')
      .eq('id', userId)
      .single();

    if (profile?.stripe_customer_id) {
      // Get active subscriptions
      const subscriptions = await stripe.subscriptions.list({
        customer: profile.stripe_customer_id,
        status: 'all'
      });

      // Cancel all active subscriptions
      for (const sub of subscriptions.data) {
        if (['active', 'trialing', 'past_due'].includes(sub.status)) {
          await stripe.subscriptions.cancel(sub.id);
        }
      }

      // Delete Stripe customer (removes payment methods)
      await stripe.customers.del(profile.stripe_customer_id);
    }

    // 2. Delete user data from database (cascade will handle related tables)
    await supabaseAdmin
      .from('subscriptions')
      .delete()
      .eq('user_id', userId);

    await supabaseAdmin
      .from('reports')
      .delete()
      .eq('user_id', userId);

    await supabaseAdmin
      .from('companies')
      .delete()
      .eq('user_id', userId);

    await supabaseAdmin
      .from('user_settings')
      .delete()
      .eq('user_id', userId);

    await supabaseAdmin
      .from('profiles')
      .delete()
      .eq('id', userId);

    // 3. Delete auth user (this will sign them out)
    await supabaseAdmin.auth.admin.deleteUser(userId);

    res.json({ success: true, message: 'Account deleted successfully' });
  } catch (err) {
    console.error('Account deletion error:', err);
    res.status(500).json({ error: 'Failed to delete account' });
  }
});

// Start server
app.listen(PORT, () => {
  console.log(`RapidReport API running on port ${PORT}`);
});

export default app;
