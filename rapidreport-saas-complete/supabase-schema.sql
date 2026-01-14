-- ============================================
-- RAPIDREPORT SAAS - SUPABASE DATABASE SCHEMA
-- Run this in Supabase SQL Editor
-- ============================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- PROFILES TABLE
-- Extended user data linked to auth.users
-- ============================================
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  email TEXT NOT NULL,
  full_name TEXT,
  avatar_url TEXT,
  stripe_customer_id TEXT UNIQUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create index for Stripe customer lookup
CREATE INDEX IF NOT EXISTS idx_profiles_stripe_customer 
ON public.profiles(stripe_customer_id);

-- ============================================
-- SUBSCRIPTIONS TABLE
-- Stripe subscription data
-- ============================================
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE UNIQUE,
  stripe_subscription_id TEXT UNIQUE,
  stripe_customer_id TEXT,
  status TEXT NOT NULL DEFAULT 'none',
  -- Status values: none, trialing, active, past_due, canceled, unpaid
  current_period_end TIMESTAMPTZ,
  trial_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN DEFAULT FALSE,
  payment_failed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for status queries
CREATE INDEX IF NOT EXISTS idx_subscriptions_status 
ON public.subscriptions(status);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user 
ON public.subscriptions(user_id);

-- ============================================
-- COMPANIES TABLE
-- Company profile data
-- ============================================
CREATE TABLE IF NOT EXISTS public.companies (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE UNIQUE,
  name TEXT,
  logo_url TEXT,
  address TEXT,
  phone TEXT,
  email TEXT,
  website TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- TEMPLATES TABLE
-- Inspection templates
-- ============================================
CREATE TABLE IF NOT EXISTS public.templates (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  statuses JSONB DEFAULT '[]'::jsonb,
  control_points JSONB DEFAULT '[]'::jsonb,
  is_default BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_templates_user 
ON public.templates(user_id);

-- ============================================
-- REPORTS TABLE
-- Inspection reports
-- ============================================
CREATE TABLE IF NOT EXISTS public.reports (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
  template_id UUID REFERENCES public.templates(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  client_name TEXT,
  location TEXT,
  status TEXT DEFAULT 'draft', -- draft, completed
  summary_title TEXT,
  summary_text TEXT,
  notes_title TEXT,
  notes_text TEXT,
  control_points JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reports_user 
ON public.reports(user_id);

CREATE INDEX IF NOT EXISTS idx_reports_status 
ON public.reports(status);

-- ============================================
-- USER SETTINGS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS public.user_settings (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE UNIQUE,
  language TEXT DEFAULT 'en',
  default_summary_title TEXT,
  default_summary_text TEXT,
  default_notes_title TEXT,
  default_notes_text TEXT,
  email_subject_template TEXT,
  email_body_template TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- ROW LEVEL SECURITY POLICIES
-- ============================================

-- Enable RLS on all tables
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;

-- Profiles: Users can only read/update their own profile
CREATE POLICY "Users can view own profile" 
ON public.profiles FOR SELECT 
USING (auth.uid() = id);

CREATE POLICY "Users can update own profile" 
ON public.profiles FOR UPDATE 
USING (auth.uid() = id);

-- Subscriptions: Users can only view their own subscription
CREATE POLICY "Users can view own subscription" 
ON public.subscriptions FOR SELECT 
USING (auth.uid() = user_id);

-- Companies: Users can CRUD their own company
CREATE POLICY "Users can view own company" 
ON public.companies FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own company" 
ON public.companies FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own company" 
ON public.companies FOR UPDATE 
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own company" 
ON public.companies FOR DELETE 
USING (auth.uid() = user_id);

-- Templates: Users can CRUD their own templates + view defaults
CREATE POLICY "Users can view own and default templates" 
ON public.templates FOR SELECT 
USING (auth.uid() = user_id OR is_default = true);

CREATE POLICY "Users can insert own templates" 
ON public.templates FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own templates" 
ON public.templates FOR UPDATE 
USING (auth.uid() = user_id AND is_default = false);

CREATE POLICY "Users can delete own templates" 
ON public.templates FOR DELETE 
USING (auth.uid() = user_id AND is_default = false);

-- Reports: Users can CRUD their own reports
CREATE POLICY "Users can view own reports" 
ON public.reports FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own reports" 
ON public.reports FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own reports" 
ON public.reports FOR UPDATE 
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own reports" 
ON public.reports FOR DELETE 
USING (auth.uid() = user_id);

-- User Settings: Users can CRUD their own settings
CREATE POLICY "Users can view own settings" 
ON public.user_settings FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own settings" 
ON public.user_settings FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own settings" 
ON public.user_settings FOR UPDATE 
USING (auth.uid() = user_id);

-- ============================================
-- FUNCTIONS & TRIGGERS
-- ============================================

-- Function to create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'avatar_url'
  );
  
  -- Create default settings
  INSERT INTO public.user_settings (user_id, language)
  VALUES (NEW.id, 'en');
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to auto-create profile
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Function to update timestamps
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add update triggers to all tables
CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_subscriptions_updated_at
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_companies_updated_at
  BEFORE UPDATE ON public.companies
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_templates_updated_at
  BEFORE UPDATE ON public.templates
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_reports_updated_at
  BEFORE UPDATE ON public.reports
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_user_settings_updated_at
  BEFORE UPDATE ON public.user_settings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ============================================
-- INSERT DEFAULT TEMPLATES
-- ============================================

INSERT INTO public.templates (id, user_id, name, description, statuses, control_points, is_default) VALUES
(
  '00000000-0000-0000-0000-000000000001',
  NULL,
  'Real Estate Inspection',
  'Property condition assessment',
  '[{"id":"good","label":"Good","color":"green"},{"id":"fair","label":"Fair","color":"orange"},{"id":"poor","label":"Poor","color":"red"}]'::jsonb,
  '[{"id":"cp1","title":"Roof"},{"id":"cp2","title":"Foundation"},{"id":"cp3","title":"Electrical"},{"id":"cp4","title":"Plumbing"},{"id":"cp5","title":"HVAC"},{"id":"cp6","title":"Windows"},{"id":"cp7","title":"Interior"},{"id":"cp8","title":"Exterior"}]'::jsonb,
  true
),
(
  '00000000-0000-0000-0000-000000000002',
  NULL,
  'Vehicle Inspection',
  'Pre-purchase or maintenance report',
  '[{"id":"pass","label":"Pass","color":"green"},{"id":"attention","label":"Needs Attention","color":"orange"},{"id":"fail","label":"Fail","color":"red"}]'::jsonb,
  '[{"id":"cp1","title":"Engine"},{"id":"cp2","title":"Transmission"},{"id":"cp3","title":"Brakes"},{"id":"cp4","title":"Suspension"},{"id":"cp5","title":"Tires"},{"id":"cp6","title":"Exterior"},{"id":"cp7","title":"Interior"},{"id":"cp8","title":"Lights"}]'::jsonb,
  true
),
(
  '00000000-0000-0000-0000-000000000003',
  NULL,
  'Restaurant Hygiene',
  'Food safety compliance',
  '[{"id":"compliant","label":"Compliant","color":"green"},{"id":"minor","label":"Minor Issue","color":"orange"},{"id":"violation","label":"Violation","color":"red"}]'::jsonb,
  '[{"id":"cp1","title":"Food Storage"},{"id":"cp2","title":"Preparation"},{"id":"cp3","title":"Equipment"},{"id":"cp4","title":"Employee Hygiene"},{"id":"cp5","title":"Pest Control"},{"id":"cp6","title":"Waste"}]'::jsonb,
  true
),
(
  '00000000-0000-0000-0000-000000000004',
  NULL,
  'Construction Safety',
  'Worksite safety assessment',
  '[{"id":"safe","label":"Safe","color":"green"},{"id":"caution","label":"Caution","color":"orange"},{"id":"hazard","label":"Hazard","color":"red"}]'::jsonb,
  '[{"id":"cp1","title":"PPE"},{"id":"cp2","title":"Fall Protection"},{"id":"cp3","title":"Electrical"},{"id":"cp4","title":"Equipment"},{"id":"cp5","title":"Housekeeping"},{"id":"cp6","title":"Fire Safety"}]'::jsonb,
  true
),
(
  '00000000-0000-0000-0000-000000000005',
  NULL,
  'Hotel Room Inspection',
  'Guest room quality assessment',
  '[{"id":"excellent","label":"Excellent","color":"green"},{"id":"acceptable","label":"Acceptable","color":"orange"},{"id":"unacceptable","label":"Unacceptable","color":"red"}]'::jsonb,
  '[{"id":"cp1","title":"Bed & Linens"},{"id":"cp2","title":"Bathroom"},{"id":"cp3","title":"Flooring"},{"id":"cp4","title":"Furniture"},{"id":"cp5","title":"Electronics"},{"id":"cp6","title":"Overall"}]'::jsonb,
  true
),
(
  '00000000-0000-0000-0000-000000000006',
  NULL,
  'Equipment Maintenance',
  'Equipment condition log',
  '[{"id":"operational","label":"Operational","color":"green"},{"id":"service","label":"Service Due","color":"orange"},{"id":"offline","label":"Out of Service","color":"red"}]'::jsonb,
  '[{"id":"cp1","title":"Visual"},{"id":"cp2","title":"Lubrication"},{"id":"cp3","title":"Electrical"},{"id":"cp4","title":"Moving Parts"},{"id":"cp5","title":"Safety"},{"id":"cp6","title":"Performance"}]'::jsonb,
  true
)
ON CONFLICT DO NOTHING;

-- ============================================
-- HELPER FUNCTION: Check subscription access
-- ============================================

CREATE OR REPLACE FUNCTION public.has_active_subscription(user_uuid UUID)
RETURNS BOOLEAN AS $$
DECLARE
  sub_status TEXT;
BEGIN
  SELECT status INTO sub_status
  FROM public.subscriptions
  WHERE user_id = user_uuid;
  
  RETURN sub_status IN ('active', 'trialing');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
