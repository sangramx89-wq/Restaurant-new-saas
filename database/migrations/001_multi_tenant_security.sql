-- ============================================================================
-- MIGRATION: 001_multi_tenant_security.sql
-- Description: Multi-tenant security foundation, Supabase Auth integration,
--              database-enforced RLS, and secure server-side order calculation.
-- Safe & Non-destructive: preserves existing tables and restaurant data.
-- ============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. Schema Updates: Link `users` and `admin_users` to `auth.users`
-- ----------------------------------------------------------------------------

-- Add auth_user_id column to users table if not exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'users' AND column_name = 'auth_user_id'
  ) THEN
    ALTER TABLE users ADD COLUMN auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

-- Create index on auth_user_id for fast RLS lookups
CREATE INDEX IF NOT EXISTS idx_users_auth_user_id ON users(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_users_email_lower ON users(LOWER(email));

-- Add auth_user_id column to admin_users table if not exists
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'admin_users' AND column_name = 'auth_user_id'
  ) THEN
    ALTER TABLE admin_users ADD COLUMN auth_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_admin_users_auth_user_id ON admin_users(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_admin_users_email_lower ON admin_users(LOWER(email));

-- ----------------------------------------------------------------------------
-- 2. Security Helper Functions
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

-- Trigger to automatically link auth_user_id on login/signup when email matches
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

-- Link trigger to auth.users if permissions allow (in Supabase Dashboard)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
    DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
    CREATE TRIGGER on_auth_user_created
      AFTER INSERT OR UPDATE ON auth.users
      FOR EACH ROW EXECUTE FUNCTION public.link_auth_user_on_login();
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Fallback if execution in restricted environment
  RAISE NOTICE 'Skipped auth.users trigger (can be manually linked via RPC or setup script)';
END $$;

-- ----------------------------------------------------------------------------
-- 3. Secure Order Creation RPC (Calculates Totals & Verifies Availability Server-Side)
-- ----------------------------------------------------------------------------

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
  v_tax_rate NUMERIC := 0.05; -- 5% GST
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
BEGIN
  -- 1. Validate restaurant exists and is active
  SELECT * INTO v_restaurant
  FROM restaurants
  WHERE id = p_restaurant_id AND is_active = TRUE AND status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Restaurant is currently inactive or does not exist');
  END IF;

  -- 2. Validate order type
  IF p_order_type NOT IN ('qr', 'counter', 'phone', 'table') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid order type');
  END IF;

  -- 3. Validate items array
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Order must contain at least one item');
  END IF;

  -- 4. Validate customer info
  IF TRIM(COALESCE(p_customer_name, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Customer name is required');
  END IF;

  IF TRIM(COALESCE(p_customer_phone, '')) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Customer phone number is required');
  END IF;

  -- 5. Loop through each item, validate availability and calculate verified prices server-side
  FOR v_item_input IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := COALESCE((v_item_input->>'quantity')::INTEGER, 1);
    IF v_qty <= 0 OR v_qty > 50 THEN
      RETURN jsonb_build_object('success', false, 'error', 'Invalid item quantity');
    END IF;

    -- Lookup menu item in database for this restaurant
    SELECT * INTO v_menu_item
    FROM menu_items
    WHERE id = (v_item_input->>'menu_item_id')::UUID
      AND restaurant_id = p_restaurant_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'Item not found in restaurant menu');
    END IF;

    IF NOT v_menu_item.is_available THEN
      RETURN jsonb_build_object('success', false, 'error', format('Item "%s" is sold out', v_menu_item.name));
    END IF;

    -- Calculate base or size price from database record (never trust client)
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

    -- Calculate add-ons price from database record
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

    -- Snapshot verified items
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

  -- 6. Calculate tax and grand total
  v_tax := ROUND(v_subtotal * v_tax_rate, 2);
  v_total := v_subtotal + v_tax;

  -- 7. Generate order number
  v_today_date := TO_CHAR(CURRENT_DATE, 'YYYYMMDD');
  SELECT COUNT(*) + 1 INTO v_order_count
  FROM orders
  WHERE restaurant_id = p_restaurant_id AND DATE(created_at) = CURRENT_DATE;

  v_order_number := v_today_date || '-' || LPAD(v_order_count::TEXT, 3, '0');

  -- 8. Insert order
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
END;
$$;

-- Allow public and authenticated callers to invoke secure order creation
GRANT EXECUTE ON FUNCTION public.create_order_secure TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Customer Order Tracking RPC (Safe projection: never leaks phone/notes)
-- ----------------------------------------------------------------------------

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

GRANT EXECUTE ON FUNCTION public.get_customer_order_status TO anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. Database-Enforced Row Level Security (RLS)
-- ----------------------------------------------------------------------------

-- Enable RLS on all tables
ALTER TABLE restaurants ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE registration_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;

-- Clean existing policies to prevent conflicts
DROP POLICY IF EXISTS "Public can view active restaurants" ON restaurants;
DROP POLICY IF EXISTS "Restaurant owners can view their restaurant" ON restaurants;
DROP POLICY IF EXISTS "Restaurant owners can update their restaurant" ON restaurants;
DROP POLICY IF EXISTS "Admins have full access to restaurants" ON restaurants;

DROP POLICY IF EXISTS "Public can view available menu items" ON menu_items;
DROP POLICY IF EXISTS "Restaurant owners can manage menu" ON menu_items;
DROP POLICY IF EXISTS "Admins have full access to menu items" ON menu_items;

DROP POLICY IF EXISTS "Public can create orders" ON orders;
DROP POLICY IF EXISTS "Restaurant owners can manage orders" ON orders;
DROP POLICY IF EXISTS "Admins have full access to orders" ON orders;

DROP POLICY IF EXISTS "Users can view self" ON users;
DROP POLICY IF EXISTS "Restaurant users view own team" ON users;
DROP POLICY IF EXISTS "Admins have full access to users" ON users;

DROP POLICY IF EXISTS "Public can submit registration requests" ON registration_requests;
DROP POLICY IF EXISTS "Admins have full access to registration requests" ON registration_requests;

DROP POLICY IF EXISTS "Admins can view admin_users" ON admin_users;

-- --- RESTAURANTS POLICIES ---
-- 1. Public can view active restaurants only
CREATE POLICY "Public can view active restaurants" 
  ON restaurants FOR SELECT 
  USING (is_active = TRUE AND status = 'active');

-- 2. Restaurant members can view their own restaurant
CREATE POLICY "Restaurant owners can view their restaurant" 
  ON restaurants FOR SELECT 
  TO authenticated 
  USING (id = public.get_auth_restaurant_id() OR public.is_admin());

-- 3. Restaurant owners and admins can update their restaurant
CREATE POLICY "Restaurant owners can update their restaurant" 
  ON restaurants FOR UPDATE 
  TO authenticated 
  USING (id = public.get_auth_restaurant_id() OR public.is_admin())
  WITH CHECK (id = public.get_auth_restaurant_id() OR public.is_admin());

-- --- MENU ITEMS POLICIES ---
-- 1. Public can only read available items for active restaurants
CREATE POLICY "Public can view published menu items" 
  ON menu_items FOR SELECT 
  USING (
    is_available = TRUE 
    AND EXISTS (
      SELECT 1 FROM restaurants 
      WHERE restaurants.id = menu_items.restaurant_id 
        AND restaurants.is_active = TRUE 
        AND restaurants.status = 'active'
    )
  );

-- 2. Restaurant members can read all items of their restaurant (even unavailable)
CREATE POLICY "Restaurant members can view own menu items" 
  ON menu_items FOR SELECT 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- 3. Restaurant members can insert items into their own restaurant
CREATE POLICY "Restaurant members can insert own menu items" 
  ON menu_items FOR INSERT 
  TO authenticated 
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- 4. Restaurant members can update their own menu items
CREATE POLICY "Restaurant members can update own menu items" 
  ON menu_items FOR UPDATE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin())
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- 5. Restaurant members can delete their own menu items
CREATE POLICY "Restaurant members can delete own menu items" 
  ON menu_items FOR DELETE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- --- ORDERS POLICIES ---
-- SECURITY CRITICAL: Public anon users CANNOT SELECT orders table directly!
-- (Customer phone numbers, addresses, and internal notes are fully shielded)
CREATE POLICY "Restaurant members can view own orders" 
  ON orders FOR SELECT 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

CREATE POLICY "Restaurant members can update own orders" 
  ON orders FOR UPDATE 
  TO authenticated 
  USING (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin())
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- Direct INSERT on orders is permitted only for authenticated staff or through create_order_secure
CREATE POLICY "Authenticated staff can insert orders" 
  ON orders FOR INSERT 
  TO authenticated 
  WITH CHECK (restaurant_id = public.get_auth_restaurant_id() OR public.is_admin());

-- --- USERS & ROLES POLICIES ---
CREATE POLICY "Users can view own profile or restaurant teammates" 
  ON users FOR SELECT 
  TO authenticated 
  USING (
    id = auth.uid() 
    OR auth_user_id = auth.uid() 
    OR restaurant_id = public.get_auth_restaurant_id() 
    OR public.is_admin()
  );

CREATE POLICY "Admins have full access to users" 
  ON users FOR ALL 
  TO authenticated 
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- --- REGISTRATION REQUESTS POLICIES ---
-- Public can submit onboarding inquiries from landing page
CREATE POLICY "Public can submit registration requests" 
  ON registration_requests FOR INSERT 
  TO anon, authenticated 
  WITH CHECK (TRUE);

-- Only platform admins can view or update registration requests
CREATE POLICY "Only admins can view registration requests" 
  ON registration_requests FOR SELECT 
  TO authenticated 
  USING (public.is_admin());

CREATE POLICY "Only admins can update registration requests" 
  ON registration_requests FOR UPDATE 
  TO authenticated 
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- --- ADMIN USERS POLICIES ---
CREATE POLICY "Admins can view admin directory" 
  ON admin_users FOR SELECT 
  TO authenticated 
  USING (public.is_admin());

-- ----------------------------------------------------------------------------
-- 6. Cleanup of Insecure Legacy Functions
-- ----------------------------------------------------------------------------

-- Drop legacy plaintext RPC login functions
DROP FUNCTION IF EXISTS public.admin_login(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.restaurant_login(TEXT, TEXT);
