-- ============================================================================
-- FINAL SUPABASE SETUP: Restaurant Ordering SaaS
-- File: database/final_supabase_setup.sql
-- Description: Complete, idempotent setup script for brand-new or existing
--              Supabase projects. Provides multi-tenant data isolation,
--              native Supabase Auth mapping, database-enforced Row Level Security
--              (RLS), server-side order calculation, and real-time support.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. EXTENSIONS
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 2. TABLES & CORE STRUCTURES
-- ----------------------------------------------------------------------------

-- 2.1 Registration Requests (Public onboarding submissions)
CREATE TABLE IF NOT EXISTS registration_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  restaurant_name TEXT NOT NULL,
  owner_name TEXT NOT NULL,
  phone TEXT NOT NULL,
  email TEXT,
  city TEXT NOT NULL,
  address TEXT,
  restaurant_type TEXT NOT NULL,
  heard_from TEXT,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'contacted', 'verified', 'rejected')),
  contacted_at TIMESTAMPTZ,
  rejection_reason TEXT,
  internal_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2.2 Restaurants (Tenants)
CREATE TABLE IF NOT EXISTS restaurants (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  registration_request_id UUID REFERENCES registration_requests(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  owner_name TEXT,
  phone TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  city TEXT,
  address TEXT,
  restaurant_type TEXT,
  logo_url TEXT,
  qr_code_url TEXT,
  subscription_plan TEXT NOT NULL DEFAULT 'free_trial' CHECK (subscription_plan IN ('free_trial', 'starter', 'pro', 'enterprise')),
  status TEXT NOT NULL DEFAULT 'trial' CHECK (status IN ('active', 'blocked', 'trial')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  internal_notes TEXT,
  block_reason TEXT,
  trial_ends_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2.3 Users (Restaurant owners & staff, mapped to Supabase Auth)
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  restaurant_id UUID REFERENCES restaurants(id) ON DELETE CASCADE,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT DEFAULT 'auth_managed',
  temp_password BOOLEAN NOT NULL DEFAULT FALSE,
  role TEXT NOT NULL DEFAULT 'owner' CHECK (role IN ('owner', 'staff', 'admin')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  last_login_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ensure auth_user_id column exists if table was pre-existing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'auth_user_id'
  ) THEN
    ALTER TABLE users ADD COLUMN auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

-- 2.4 Menu Categories
CREATE TABLE IF NOT EXISTS menu_categories (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  display_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(restaurant_id, name)
);

-- 2.5 Menu Items
CREATE TABLE IF NOT EXISTS menu_items (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  category_id UUID REFERENCES menu_categories(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  description TEXT,
  base_price DECIMAL(10, 2) NOT NULL CHECK (base_price >= 0),
  image_url TEXT,
  is_available BOOLEAN NOT NULL DEFAULT TRUE,
  is_featured BOOLEAN NOT NULL DEFAULT FALSE,
  sizes JSONB DEFAULT '[]'::jsonb,
  addons JSONB DEFAULT '[]'::jsonb,
  tags TEXT[] DEFAULT '{}',
  prep_time_minutes INTEGER,
  display_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2.6 Orders
CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  order_number TEXT NOT NULL,
  order_type TEXT NOT NULL CHECK (order_type IN ('qr', 'counter', 'phone', 'table')),
  table_number TEXT,
  customer_name TEXT,
  customer_phone TEXT,
  items JSONB NOT NULL,
  subtotal DECIMAL(10, 2) NOT NULL CHECK (subtotal >= 0),
  tax DECIMAL(10, 2) NOT NULL DEFAULT 0 CHECK (tax >= 0),
  discount DECIMAL(10, 2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  total DECIMAL(10, 2) NOT NULL CHECK (total >= 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'preparing', 'ready', 'completed', 'cancelled', 'rejected')),
  payment_method TEXT,
  payment_status TEXT DEFAULT 'pending' CHECK (payment_status IN ('pending', 'paid', 'failed')),
  payment_transaction_id TEXT,
  customer_notes TEXT,
  internal_notes TEXT,
  accepted_at TIMESTAMPTZ,
  preparing_at TIMESTAMPTZ,
  ready_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(restaurant_id, order_number)
);

-- 2.7 Platform Admin Users
CREATE TABLE IF NOT EXISTS admin_users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  email TEXT NOT NULL UNIQUE,
  name TEXT,
  is_super_admin BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  last_login_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ensure auth_user_id exists if pre-existing
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'admin_users' AND column_name = 'auth_user_id'
  ) THEN
    ALTER TABLE admin_users ADD COLUMN auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

-- 2.8 Notifications
CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  restaurant_id UUID REFERENCES restaurants(id) ON DELETE CASCADE,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  data JSONB,
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 3. INDEXES FOR PERFORMANCE & SECURITY LOOKUPS
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_registration_requests_status ON registration_requests(status);
CREATE INDEX IF NOT EXISTS idx_registration_requests_created_at ON registration_requests(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_restaurants_slug ON restaurants(slug);
CREATE INDEX IF NOT EXISTS idx_restaurants_status ON restaurants(status);
CREATE INDEX IF NOT EXISTS idx_restaurants_is_active ON restaurants(is_active);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_email_lower ON users(LOWER(email));
CREATE INDEX IF NOT EXISTS idx_users_auth_user_id ON users(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_users_restaurant_id ON users(restaurant_id);

CREATE INDEX IF NOT EXISTS idx_menu_categories_restaurant_id ON menu_categories(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_menu_categories_is_active ON menu_categories(is_active);

CREATE INDEX IF NOT EXISTS idx_menu_items_restaurant_id ON menu_items(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_menu_items_category_id ON menu_items(category_id);
CREATE INDEX IF NOT EXISTS idx_menu_items_is_available ON menu_items(restaurant_id, is_available);

CREATE INDEX IF NOT EXISTS idx_orders_restaurant_id ON orders(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(restaurant_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(restaurant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_users_email ON admin_users(email);
CREATE INDEX IF NOT EXISTS idx_admin_users_email_lower ON admin_users(LOWER(email));
CREATE INDEX IF NOT EXISTS idx_admin_users_auth_user_id ON admin_users(auth_user_id);

CREATE INDEX IF NOT EXISTS idx_notifications_restaurant_id ON notifications(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_is_read ON notifications(is_read);

-- ----------------------------------------------------------------------------
-- 4. AUTO-UPDATE TIMESTAMPS TRIGGERS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_registration_requests_updated_at ON registration_requests;
CREATE TRIGGER update_registration_requests_updated_at BEFORE UPDATE ON registration_requests FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_restaurants_updated_at ON restaurants;
CREATE TRIGGER update_restaurants_updated_at BEFORE UPDATE ON restaurants FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_users_updated_at ON users;
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_menu_categories_updated_at ON menu_categories;
CREATE TRIGGER update_menu_categories_updated_at BEFORE UPDATE ON menu_categories FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_menu_items_updated_at ON menu_items;
CREATE TRIGGER update_menu_items_updated_at BEFORE UPDATE ON menu_items FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_orders_updated_at ON orders;
CREATE TRIGGER update_orders_updated_at BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_admin_users_updated_at ON admin_users;
CREATE TRIGGER update_admin_users_updated_at BEFORE UPDATE ON admin_users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ----------------------------------------------------------------------------
-- 5. AUTHENTICATION & MULTI-TENANT CONTEXT FUNCTIONS
-- ----------------------------------------------------------------------------

-- Returns the restaurant_id belonging to the currently authenticated user
CREATE OR REPLACE FUNCTION public.get_auth_restaurant_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT restaurant_id 
  FROM users 
  WHERE (
    auth_user_id = auth.uid() 
    OR id = auth.uid() 
    OR LOWER(email) = LOWER(auth.jwt()->>'email')
  )
  AND is_active = TRUE
  LIMIT 1;
$$;

-- Returns true if the currently authenticated user is an active system admin
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 
    FROM admin_users 
    WHERE (
      auth_user_id = auth.uid() 
      OR id = auth.uid() 
      OR LOWER(email) = LOWER(auth.jwt()->>'email')
    )
    AND is_active = TRUE
  );
$$;

-- Returns the user's role ('owner', 'staff', 'admin')
CREATE OR REPLACE FUNCTION public.get_auth_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 
    CASE 
      WHEN EXISTS (
        SELECT 1 FROM admin_users 
        WHERE (auth_user_id = auth.uid() OR id = auth.uid() OR LOWER(email) = LOWER(auth.jwt()->>'email'))
        AND is_active = TRUE
      ) THEN 'admin'
      ELSE (
        SELECT role FROM users 
        WHERE (auth_user_id = auth.uid() OR id = auth.uid() OR LOWER(email) = LOWER(auth.jwt()->>'email'))
        AND is_active = TRUE
        LIMIT 1
      )
    END;
$$;

-- Trigger to automatically link auth_user_id when a user signs up or signs in via Supabase Auth
CREATE OR REPLACE FUNCTION public.link_auth_user_on_login()
RETURNS TRIGGER AS $$
BEGIN
  -- Link tenant users
  UPDATE public.users
  SET auth_user_id = NEW.id
  WHERE LOWER(email) = LOWER(NEW.email) AND (auth_user_id IS NULL OR auth_user_id != NEW.id);

  -- Link admin users
  UPDATE public.admin_users
  SET auth_user_id = NEW.id
  WHERE LOWER(email) = LOWER(NEW.email) AND (auth_user_id IS NULL OR auth_user_id != NEW.id);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Link trigger to auth.users if permissions allow (handled safely in Supabase environments)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
    DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
    CREATE TRIGGER on_auth_user_created
      AFTER INSERT OR UPDATE ON auth.users
      FOR EACH ROW EXECUTE FUNCTION public.link_auth_user_on_login();
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Skipped auth.users trigger installation; automatic fallback via JWT email mapping is active.';
END $$;

-- ----------------------------------------------------------------------------
-- 6. SECURE BUSINESS RPC FUNCTIONS
-- ----------------------------------------------------------------------------

-- 6.1 Secure Order Creation Function (Server-Side Pricing & Availability Validation)
CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_restaurant_id UUID,
  p_order_type TEXT,
  p_table_number TEXT,
  p_customer_name TEXT,
  p_customer_phone TEXT,
  p_items JSONB,
  p_customer_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_restaurant RECORD;
  v_item_input JSONB;
  v_menu_item RECORD;
  v_validated_items JSONB := '[]'::jsonb;
  v_subtotal NUMERIC := 0;
  v_tax NUMERIC := 0;
  v_total NUMERIC := 0;
  v_tax_rate NUMERIC := 0.05; -- Standard 5% GST
  v_order_id UUID;
  v_order_number TEXT;
  v_item_price NUMERIC;
  v_item_total NUMERIC;
  v_qty INTEGER;
  v_size_name TEXT;
  v_size_price NUMERIC;
  v_addon JSONB;
  v_addons_price NUMERIC;
  v_today_date TEXT;
  v_order_count INTEGER;
  v_item_id UUID;
BEGIN
  -- 1. Validate restaurant exists and is active (active or trial, not blocked)
  SELECT * INTO v_restaurant
  FROM restaurants
  WHERE id = p_restaurant_id AND is_active = TRUE AND status != 'blocked';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Restaurant is currently unavailable or inactive');
  END IF;

  -- 2. Validate order type
  IF p_order_type NOT IN ('qr', 'counter', 'phone', 'table') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid order type');
  END IF;

  -- 3. Validate items
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Order must contain at least one item');
  END IF;

  IF TRIM(COALESCE(p_customer_name, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Customer name is required');
  END IF;

  IF TRIM(COALESCE(p_customer_phone, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Customer phone number is required');
  END IF;

  -- 4. Calculate prices server-side from database records
  FOR v_item_input IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := COALESCE((v_item_input->>'quantity')::INTEGER, 1);
    IF v_qty <= 0 OR v_qty > 50 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Invalid item quantity (must be between 1 and 50)');
    END IF;

    BEGIN
      v_item_id := (v_item_input->>'menu_item_id')::UUID;
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object('success', false, 'error', 'Invalid menu item ID format');
    END;

    SELECT * INTO v_menu_item
    FROM menu_items
    WHERE id = v_item_id AND restaurant_id = p_restaurant_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'One or more items do not exist on the current menu');
    END IF;

    IF NOT v_menu_item.is_available THEN
      RETURN jsonb_build_object('success', false, 'error', format('Item "%s" is sold out', v_menu_item.name));
    END IF;

    -- Base or size price lookup
    v_item_price := v_menu_item.base_price;
    v_size_name := v_item_input->'selected_size'->>'name';

    IF v_size_name IS NOT NULL AND v_menu_item.sizes IS NOT NULL THEN
      SELECT (elem->>'price')::NUMERIC INTO v_size_price
      FROM jsonb_array_elements(v_menu_item.sizes) elem
      WHERE elem->>'name' = v_size_name
      LIMIT 1;

      IF v_size_price IS NOT NULL THEN
        v_item_price := v_size_price;
      END IF;
    END IF;

    -- Add-ons lookup from database
    v_addons_price := 0;
    IF v_item_input->'selected_addons' IS NOT NULL AND jsonb_array_length(v_item_input->'selected_addons') > 0 THEN
      FOR v_addon IN SELECT * FROM jsonb_array_elements(v_item_input->'selected_addons')
      LOOP
        DECLARE
          v_addon_name TEXT := v_addon->>'name';
          v_db_addon_price NUMERIC;
        BEGIN
          SELECT (elem->>'price')::NUMERIC INTO v_db_addon_price
          FROM jsonb_array_elements(v_menu_item.addons) elem
          WHERE elem->>'name' = v_addon_name
          LIMIT 1;

          IF v_db_addon_price IS NOT NULL THEN
            v_addons_price := v_addons_price + v_db_addon_price;
          END IF;
        END;
      END LOOP;
    END IF;

    v_item_total := (v_item_price + v_addons_price) * v_qty;
    v_subtotal := v_subtotal + v_item_total;

    v_validated_items := v_validated_items || jsonb_build_object(
      'menu_item_id', v_menu_item.id,
      'name', v_menu_item.name,
      'quantity', v_qty,
      'base_price', v_item_price,
      'selected_size', v_item_input->'selected_size',
      'selected_addons', COALESCE(v_item_input->'selected_addons', '[]'::jsonb),
      'item_total', v_item_total,
      'special_instructions', v_item_input->>'special_instructions'
    );
  END LOOP;

  v_tax := ROUND(v_subtotal * v_tax_rate, 2);
  v_total := v_subtotal + v_tax;

  -- Generate unique sequential order number for today
  v_today_date := TO_CHAR(CURRENT_DATE, 'YYYYMMDD');
  SELECT COUNT(*) + 1 INTO v_order_count
  FROM orders
  WHERE restaurant_id = p_restaurant_id AND DATE(created_at) = CURRENT_DATE;

  v_order_number := v_today_date || '-' || LPAD(v_order_count::TEXT, 3, '0');

  -- Handle rare concurrency collision
  WHILE EXISTS (SELECT 1 FROM orders WHERE restaurant_id = p_restaurant_id AND order_number = v_order_number) LOOP
    v_order_count := v_order_count + 1;
    v_order_number := v_today_date || '-' || LPAD(v_order_count::TEXT, 3, '0') || '-' || SUBSTRING(gen_random_uuid()::TEXT, 1, 4);
  END LOOP;

  INSERT INTO orders (
    restaurant_id,
    order_number,
    order_type,
    table_number,
    customer_name,
    customer_phone,
    items,
    subtotal,
    tax,
    discount,
    total,
    status,
    customer_notes
  ) VALUES (
    p_restaurant_id,
    v_order_number,
    p_order_type,
    p_table_number,
    p_customer_name,
    p_customer_phone,
    v_validated_items,
    v_subtotal,
    v_tax,
    0,
    v_total,
    'pending',
    p_customer_notes
  )
  RETURNING id INTO v_order_id;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'order_number', v_order_number,
    'subtotal', v_subtotal,
    'tax', v_tax,
    'total', v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- 6.2 Safe Customer Order Status RPC (Safe projection: never leaks phone, address, or customer notes)
CREATE OR REPLACE FUNCTION public.get_customer_order_status(
  p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_restaurant_name TEXT;
BEGIN
  SELECT o.*, r.name as restaurant_name 
  INTO v_order
  FROM orders o
  JOIN restaurants r ON r.id = o.restaurant_id
  WHERE o.id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Order not found');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'restaurant_name', v_order.restaurant_name,
    'status', v_order.status,
    'order_type', v_order.order_type,
    'table_number', v_order.table_number,
    'subtotal', v_order.subtotal,
    'tax', v_order.tax,
    'total', v_order.total,
    'items', v_order.items,
    'created_at', v_order.created_at,
    'accepted_at', v_order.accepted_at,
    'preparing_at', v_order.preparing_at,
    'ready_at', v_order.ready_at,
    'completed_at', v_order.completed_at
  );
END;
$$;

-- 6.3 Admin Create Restaurant Function (Admin-only RPC)
CREATE OR REPLACE FUNCTION public.admin_create_restaurant(
  p_request_id UUID,
  p_restaurant_name TEXT,
  p_slug TEXT,
  p_owner_name TEXT,
  p_phone TEXT,
  p_email TEXT,
  p_city TEXT,
  p_address TEXT,
  p_subscription_plan TEXT,
  p_internal_notes TEXT DEFAULT NULL
)
RETURNS TABLE (
  restaurant_id UUID,
  user_id UUID,
  success BOOLEAN,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_restaurant_id UUID;
  v_user_id UUID;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN QUERY SELECT NULL::UUID, NULL::UUID, FALSE, 'Unauthorized: Admin privileges required'::TEXT;
    RETURN;
  END IF;

  INSERT INTO restaurants (
    registration_request_id, name, slug, owner_name, phone, email,
    city, address, subscription_plan, status, is_active
  ) VALUES (
    p_request_id, p_restaurant_name, p_slug, p_owner_name, p_phone, p_email,
    p_city, p_address, p_subscription_plan, 'active', TRUE
  )
  RETURNING id INTO v_restaurant_id;

  INSERT INTO users (restaurant_id, email, password_hash, temp_password, role)
  VALUES (v_restaurant_id, p_email, 'auth_managed', TRUE, 'owner')
  RETURNING id INTO v_user_id;

  IF p_request_id IS NOT NULL THEN
    UPDATE registration_requests
    SET status = 'verified', contacted_at = NOW(), internal_notes = p_internal_notes
    WHERE id = p_request_id;
  END IF;

  RETURN QUERY SELECT v_restaurant_id, v_user_id, TRUE, 'Restaurant created successfully'::TEXT;

EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT NULL::UUID, NULL::UUID, FALSE, SQLERRM;
END;
$$;

-- 6.4 Admin Toggle Restaurant Status Function (Admin-only RPC)
CREATE OR REPLACE FUNCTION public.admin_toggle_restaurant_status(
  p_restaurant_id UUID,
  p_is_active BOOLEAN,
  p_block_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Admin privileges required';
  END IF;

  UPDATE restaurants
  SET 
    is_active = p_is_active,
    status = CASE WHEN p_is_active THEN 'active' ELSE 'blocked' END,
    block_reason = p_block_reason
  WHERE id = p_restaurant_id;

  RETURN TRUE;
END;
$$;

-- 6.5 Admin Reject Registration Request Function (Admin-only RPC)
CREATE OR REPLACE FUNCTION public.admin_reject_request(
  p_request_id UUID,
  p_rejection_reason TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Unauthorized: Admin privileges required';
  END IF;

  UPDATE registration_requests
  SET 
    status = 'rejected',
    rejection_reason = p_rejection_reason,
    contacted_at = NOW()
  WHERE id = p_request_id;

  RETURN TRUE;
END;
$$;

-- Drop legacy plaintext RPC login functions if present
DROP FUNCTION IF EXISTS public.admin_login(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.restaurant_login(TEXT, TEXT);

-- ----------------------------------------------------------------------------
-- 7. FUNCTION PERMISSIONS & GRANTS
-- ----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.get_auth_restaurant_id TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.is_admin TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_auth_role TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.create_order_secure TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_order_status TO anon, authenticated;

-- Strictly restrict admin functions
REVOKE ALL ON FUNCTION public.admin_create_restaurant(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_restaurant(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_toggle_restaurant_status(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_toggle_restaurant_status(UUID, BOOLEAN, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_reject_request(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reject_request(UUID, TEXT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY (RLS) POLICIES
-- ----------------------------------------------------------------------------

-- Enable RLS on every table
ALTER TABLE registration_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurants ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- Clean existing policies for idempotency
DROP POLICY IF EXISTS "Public can submit registration requests" ON registration_requests;
DROP POLICY IF EXISTS "Only admins can view registration requests" ON registration_requests;
DROP POLICY IF EXISTS "Only admins can update registration requests" ON registration_requests;
DROP POLICY IF EXISTS "Only admins can delete registration requests" ON registration_requests;

DROP POLICY IF EXISTS "Public can view active restaurants" ON restaurants;
DROP POLICY IF EXISTS "Restaurant owners can view their restaurant" ON restaurants;
DROP POLICY IF EXISTS "Restaurant owners can update their restaurant" ON restaurants;
DROP POLICY IF EXISTS "Admins have full access to restaurants" ON restaurants;

DROP POLICY IF EXISTS "Users can view own profile or restaurant teammates" ON users;
DROP POLICY IF EXISTS "Restaurant owners can manage staff" ON users;
DROP POLICY IF EXISTS "Users can update own profile or team" ON users;
DROP POLICY IF EXISTS "Restaurant owners or admins can delete users" ON users;
DROP POLICY IF EXISTS "Admins have full access to users" ON users;

DROP POLICY IF EXISTS "Public can view active menu categories" ON menu_categories;
DROP POLICY IF EXISTS "Restaurant members can view own menu categories" ON menu_categories;
DROP POLICY IF EXISTS "Restaurant members can insert own menu categories" ON menu_categories;
DROP POLICY IF EXISTS "Restaurant members can update own menu categories" ON menu_categories;
DROP POLICY IF EXISTS "Restaurant members can delete own menu categories" ON menu_categories;

DROP POLICY IF EXISTS "Public can view published menu items" ON menu_items;
DROP POLICY IF EXISTS "Restaurant members can view own menu items" ON menu_items;
DROP POLICY IF EXISTS "Restaurant members can insert own menu items" ON menu_items;
DROP POLICY IF EXISTS "Restaurant members can update own menu items" ON menu_items;
DROP POLICY IF EXISTS "Restaurant members can delete own menu items" ON menu_items;

DROP POLICY IF EXISTS "Restaurant members can view own orders" ON orders;
DROP POLICY IF EXISTS "Restaurant members can update own orders" ON orders;
DROP POLICY IF EXISTS "Authenticated staff can insert orders" ON orders;
DROP POLICY IF EXISTS "Admins can delete orders" ON orders;

DROP POLICY IF EXISTS "Admins can view admin directory" ON admin_users;
DROP POLICY IF EXISTS "Admins can update admin profiles" ON admin_users;
DROP POLICY IF EXISTS "Admins can insert admin users" ON admin_users;
DROP POLICY IF EXISTS "Admins can delete admin users" ON admin_users;

DROP POLICY IF EXISTS "Users can view own or restaurant notifications" ON notifications;
DROP POLICY IF EXISTS "Users can insert notifications" ON notifications;
DROP POLICY IF EXISTS "Users can update notifications" ON notifications;
DROP POLICY IF EXISTS "Users can delete notifications" ON notifications;

-- ============================================================================
-- 8.1 REGISTRATION REQUESTS POLICIES
-- ============================================================================
-- Public can submit onboarding inquiries
CREATE POLICY "Public can submit registration requests" 
  ON registration_requests FOR INSERT 
  TO anon, authenticated 
  WITH CHECK (TRUE);

-- Only platform admins can view or manage registration requests
CREATE POLICY "Only admins can view registration requests" 
  ON registration_requests FOR SELECT 
  TO authenticated 
  USING (public.is_admin());

CREATE POLICY "Only admins can update registration requests" 
  ON registration_requests FOR UPDATE 
  TO authenticated 
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "Only admins can delete registration requests" 
  ON registration_requests FOR DELETE 
  TO authenticated 
  USING (public.is_admin());

-- ============================================================================
-- 8.2 RESTAURANTS POLICIES
-- ============================================================================
-- Public customers can view active/trial restaurants
CREATE POLICY "Public can view active restaurants" 
  ON restaurants FOR SELECT 
  USING (is_active = TRUE AND status != 'blocked');

-- Authenticated restaurant members can view their own restaurant
CREATE POLICY "Restaurant owners can view their restaurant" 
  ON restaurants FOR SELECT 
  TO authenticated 
  USING (id = public.get_auth_restaurant_id() OR public.is_admin());

-- Authenticated restaurant owners can update their restaurant settings
CREATE POLICY "Restaurant owners can update their restaurant" 
  ON restaurants FOR UPDATE 
  TO authenticated 
  USING (id = public.get_auth_restaurant_id() OR public.is_admin())
  WITH CHECK (id = public.get_auth_restaurant_id() OR public.is_admin());

-- Platform admins have full operational access to restaurants
CREATE POLICY "Admins have full access to restaurants" 
  ON restaurants FOR ALL 
  TO authenticated 
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================================================
-- 8.3 USERS & ROLES POLICIES
-- ============================================================================
CREATE POLICY "Users can view own profile or restaurant teammates" 
  ON users FOR SELECT 
  TO authenticated 
  USING (
    id = auth.uid() 
    OR auth_user_id = auth.uid() 
    OR LOWER(email) = LOWER(auth.jwt()->>'email')
    OR restaurant_id = public.get_auth_restaurant_id() 
    OR public.is_admin()
  );

CREATE POLICY "Restaurant owners can manage staff" 
  ON users FOR INSERT 
  TO authenticated 
  WITH CHECK (
    restaurant_id = public.get_auth_restaurant_id() 
    OR public.is_admin()
  );

CREATE POLICY "Users can update own profile or team" 
  ON users FOR UPDATE 
  TO authenticated 
  USING (
    id = auth.uid() 
    OR auth_user_id = auth.uid() 
    OR LOWER(email) = LOWER(auth.jwt()->>'email')
    OR restaurant_id = public.get_auth_restaurant_id() 
    OR public.is_admin()
  )
  WITH CHECK (
    id = auth.uid() 
    OR auth_user_id = auth.uid() 
    OR LOWER(email) = LOWER(auth.jwt()->>'email')
    OR restaurant_id = public.get_auth_restaurant_id() 
    OR public.is_admin()
  );

CREATE POLICY "Restaurant owners or admins can delete users" 
  ON users FOR DELETE 
  TO authenticated 
  USING (
    (restaurant_id = public.get_auth_restaurant_id() AND public.get_auth_role() = 'owner')
    OR public.is_admin()
  );

CREATE POLICY "Admins have full access to users" 
  ON users FOR ALL 
  TO authenticated 
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================================================
-- 8.4 MENU CATEGORIES POLICIES
-- ============================================================================
CREATE POLICY "Public can view active menu categories" 
  ON menu_categories FOR SELECT 
  USING (
    is_active = TRUE 
    AND EXISTS (
      SELECT 1 FROM restaurants 
      WHERE restaurants.id = menu_categories.restaurant_id 
        AND restaurants.is_active = TRUE 
        AND restaurants.status != 'blocked'
    )
  );

CREATE POLICY "Restaurant members can view own menu categories" 
  ON menu_categories FOR SELECT 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can insert own menu categories" 
  ON menu_categories FOR INSERT 
  TO authenticated 
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can update own menu categories" 
  ON menu_categories FOR UPDATE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin())
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can delete own menu categories" 
  ON menu_categories FOR DELETE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- ============================================================================
-- 8.5 MENU ITEMS POLICIES
-- ============================================================================
CREATE POLICY "Public can view published menu items" 
  ON menu_items FOR SELECT 
  USING (
    is_available = TRUE 
    AND EXISTS (
      SELECT 1 FROM restaurants 
      WHERE restaurants.id = menu_items.restaurant_id 
        AND restaurants.is_active = TRUE 
        AND restaurants.status != 'blocked'
    )
  );

CREATE POLICY "Restaurant members can view own menu items" 
  ON menu_items FOR SELECT 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can insert own menu items" 
  ON menu_items FOR INSERT 
  TO authenticated 
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can update own menu items" 
  ON menu_items FOR UPDATE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin())
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can delete own menu items" 
  ON menu_items FOR DELETE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- ============================================================================
-- 8.6 ORDERS POLICIES (NO DIRECT PUBLIC ACCESS TO ORDERS TABLE)
-- ============================================================================
CREATE POLICY "Restaurant members can view own orders" 
  ON orders FOR SELECT 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can update own orders" 
  ON orders FOR UPDATE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin())
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Authenticated staff can insert orders" 
  ON orders FOR INSERT 
  TO authenticated 
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Admins can delete orders" 
  ON orders FOR DELETE 
  TO authenticated 
  USING (public.is_admin());

-- ============================================================================
-- 8.7 ADMIN USERS POLICIES
-- ============================================================================
CREATE POLICY "Admins can view admin directory" 
  ON admin_users FOR SELECT 
  TO authenticated 
  USING (public.is_admin());

CREATE POLICY "Admins can update admin profiles" 
  ON admin_users FOR UPDATE 
  TO authenticated 
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

CREATE POLICY "Admins can insert admin users" 
  ON admin_users FOR INSERT 
  TO authenticated 
  WITH CHECK (public.is_admin());

CREATE POLICY "Admins can delete admin users" 
  ON admin_users FOR DELETE 
  TO authenticated 
  USING (public.is_admin());

-- ============================================================================
-- 8.8 NOTIFICATIONS POLICIES
-- ============================================================================
CREATE POLICY "Users can view own or restaurant notifications" 
  ON notifications FOR SELECT 
  TO authenticated 
  USING (
    restaurant_id = public.get_auth_restaurant_id() 
    OR user_id = auth.uid() 
    OR public.is_admin()
  );

CREATE POLICY "Users can insert notifications" 
  ON notifications FOR INSERT 
  TO authenticated 
  WITH CHECK (
    restaurant_id = public.get_auth_restaurant_id() 
    OR user_id = auth.uid() 
    OR public.is_admin()
  );

CREATE POLICY "Users can update notifications" 
  ON notifications FOR UPDATE 
  TO authenticated 
  USING (
    restaurant_id = public.get_auth_restaurant_id() 
    OR user_id = auth.uid() 
    OR public.is_admin()
  )
  WITH CHECK (
    restaurant_id = public.get_auth_restaurant_id() 
    OR user_id = auth.uid() 
    OR public.is_admin()
  );

CREATE POLICY "Users can delete notifications" 
  ON notifications FOR DELETE 
  TO authenticated 
  USING (
    restaurant_id = public.get_auth_restaurant_id() 
    OR user_id = auth.uid() 
    OR public.is_admin()
  );

-- ----------------------------------------------------------------------------
-- 9. REAL-TIME REPLICATION CONFIGURATION
-- ----------------------------------------------------------------------------
ALTER TABLE registration_requests REPLICA IDENTITY FULL;
ALTER TABLE restaurants REPLICA IDENTITY FULL;
ALTER TABLE menu_categories REPLICA IDENTITY FULL;
ALTER TABLE menu_items REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE notifications REPLICA IDENTITY FULL;

-- Safely add tables to supabase_realtime publication
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE registration_requests;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE restaurants;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE menu_categories;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE menu_items;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE orders;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE notifications;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- ----------------------------------------------------------------------------
-- 10. INITIAL SYSTEM ADMIN SEED (Safe & Idempotent)
-- ----------------------------------------------------------------------------
-- Seeds a system admin placeholder email. When this user registers or signs in
-- using Supabase Auth (e.g. Email/Password in auth.users), they are automatically
-- granted full admin access via link_auth_user_on_login() and is_admin().
INSERT INTO admin_users (email, name, is_super_admin, is_active)
VALUES ('admin@foodorder.com', 'System Admin', TRUE, TRUE)
ON CONFLICT (email) DO UPDATE SET is_active = TRUE;

-- ============================================================================
-- SETUP COMPLETE
-- ============================================================================
