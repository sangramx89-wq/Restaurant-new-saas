import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./config";

// Database types
export interface RegistrationRequest {
  id: string;
  restaurant_name: string;
  owner_name: string;
  phone: string;
  email?: string;
  city: string;
  address?: string;
  restaurant_type: string;
  heard_from?: string;
  notes?: string;
  status: "pending" | "contacted" | "verified" | "rejected";
  contacted_at?: string;
  rejection_reason?: string;
  internal_notes?: string;
  created_at: string;
}

export interface Restaurant {
  id: string;
  registration_request_id?: string;
  name: string;
  slug: string;
  owner_name?: string;
  phone: string;
  email: string;
  city?: string;
  address?: string;
  restaurant_type?: string;
  logo_url?: string;
  qr_code_url?: string;
  subscription_plan: "free_trial" | "starter" | "pro" | "enterprise";
  status: "active" | "blocked" | "trial";
  is_active: boolean;
  internal_notes?: string;
  block_reason?: string;
  trial_ends_at?: string;
  created_at: string;
  updated_at: string;
}

export interface User {
  id: string;
  auth_user_id?: string;
  restaurant_id?: string;
  email: string;
  temp_password?: boolean;
  role: "owner" | "staff" | "admin";
  is_active?: boolean;
  created_at: string;
  restaurants?: Restaurant;
}

export interface MenuItem {
  id: string;
  restaurant_id: string;
  name: string;
  description?: string;
  base_price: number;
  category?: string;
  image_url?: string;
  is_available: boolean;
  sizes?: { name: string; price: number }[];
  addons?: { name: string; price: number }[];
  created_at: string;
}

export interface Order {
  id: string;
  restaurant_id: string;
  order_number: string;
  order_type: "qr" | "counter" | "phone" | "table";
  table_number?: string;
  customer_name?: string;
  customer_phone?: string;
  items: OrderItem[];
  subtotal: number;
  tax: number;
  discount?: number;
  total: number;
  status:
    | "pending"
    | "accepted"
    | "preparing"
    | "ready"
    | "completed"
    | "cancelled"
    | "rejected";
  payment_method?: string;
  payment_status?: string;
  payment_transaction_id?: string;
  customer_notes?: string;
  internal_notes?: string;
  accepted_at?: string;
  preparing_at?: string;
  ready_at?: string;
  completed_at?: string;
  cancelled_at?: string;
  created_at: string;
  updated_at?: string;
}

export interface OrderItem {
  menu_item_id: string;
  name: string;
  quantity: number;
  base_price: number;
  selected_size?: { name: string; price: number };
  selected_addons?: { name: string; price: number }[];
  item_total: number;
  special_instructions?: string;
}

export interface AdminUser {
  id: string;
  auth_user_id?: string;
  email: string;
  name?: string;
  is_super_admin?: boolean;
  is_active?: boolean;
  created_at: string;
}

// ============================================================================
// Configuration Validation & Environment Detection
// ============================================================================

export const isRealSupabaseConfigured = (): boolean => {
  if (!SUPABASE_URL || typeof SUPABASE_URL !== "string") return false;
  if (!SUPABASE_URL.startsWith("http://") && !SUPABASE_URL.startsWith("https://")) return false;
  if (SUPABASE_URL.includes("YOUR_SUPABASE_URL")) return false;
  if (!SUPABASE_ANON_KEY || SUPABASE_ANON_KEY.includes("YOUR_SUPABASE_ANON_KEY")) return false;
  return true;
};

export const isProduction = Boolean(import.meta.env.PROD);

// ============================================================================
// Unconfigured Production Client
// In production, NEVER silently fall back to mock data. Report error explicitly.
// ============================================================================
class UnconfiguredProductionClient {
  auth = {
    signInWithPassword: async () => ({
      data: { user: null, session: null },
      error: { message: "Production database is not configured. Please set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in your environment." },
    }),
    signUp: async () => ({
      data: { user: null, session: null },
      error: { message: "Production database is not configured. Please set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in your environment." },
    }),
    signOut: async () => ({ error: null }),
    getSession: async () => ({ data: { session: null }, error: null }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
  };

  from(_table: string) {
    const errorResult = {
      data: null,
      error: { message: "Production database is not configured. Please set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in your environment." },
    };
    return {
      select: () => this.from(_table),
      insert: () => this.from(_table),
      update: () => this.from(_table),
      delete: () => this.from(_table),
      eq: () => this.from(_table),
      gte: () => this.from(_table),
      lte: () => this.from(_table),
      in: () => this.from(_table),
      order: () => this.from(_table),
      single: () => this.from(_table),
      then: (resolve: any) => Promise.resolve(resolve(errorResult)),
    };
  }

  async rpc(_name: string) {
    return {
      data: null,
      error: { message: "Production database is not configured. Please set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in your environment." },
    };
  }

  channel(_name: string) {
    return {
      on: () => ({
        subscribe: () => ({ unsubscribe: () => {} }),
      }),
      subscribe: () => ({ unsubscribe: () => {} }),
    };
  }
}

// ============================================================================
// Development Sandbox Mock Database Layer (Strict Dev Mode Only)
// ============================================================================

type Listener = (payload: any) => void;
const listeners: Map<string, Set<Listener>> = new Map();

const notifyListeners = (table: string, event: string, record: any) => {
  const tableListeners = listeners.get(table);
  if (tableListeners) {
    tableListeners.forEach((fn) => {
      try {
        fn({ eventType: event, new: record, old: record, table });
      } catch (err) {
        console.error("Sandbox listener error:", err);
      }
    });
  }
};

const STORAGE_PREFIX = "foodorder_sandbox_";

const getStoredTable = <T>(tableName: string, defaultData: T[]): T[] => {
  try {
    const data = localStorage.getItem(`${STORAGE_PREFIX}${tableName}`);
    if (data) return JSON.parse(data);
  } catch (e) {
    console.warn("Failed to load table from localStorage:", tableName, e);
  }
  return defaultData;
};

const saveStoredTable = <T>(tableName: string, data: T[]) => {
  try {
    localStorage.setItem(`${STORAGE_PREFIX}${tableName}`, JSON.stringify(data));
  } catch (e) {
    console.warn("Failed to save table to localStorage:", tableName, e);
  }
};

// Initial Sandbox Data
const SANDBOX_ADMINS: AdminUser[] = [
  {
    id: "admin-001",
    auth_user_id: "auth-admin-001",
    email: "admin@foodorder.com",
    name: "System Admin",
    is_super_admin: true,
    is_active: true,
    created_at: new Date("2025-01-01").toISOString(),
  },
];

const SANDBOX_RESTAURANTS: Restaurant[] = [
  {
    id: "rest-spicy-kitchen",
    name: "Spicy Kitchen",
    slug: "spicy-kitchen",
    owner_name: "Rahul Sharma",
    phone: "9876543210",
    email: "owner@spicykitchen.com",
    city: "Mumbai",
    address: "123 Marine Drive, Mumbai",
    restaurant_type: "Restaurant",
    subscription_plan: "pro",
    status: "active",
    is_active: true,
    created_at: new Date("2025-01-01").toISOString(),
    updated_at: new Date("2025-01-01").toISOString(),
  },
];

const SANDBOX_USERS: User[] = [
  {
    id: "user-spicy-kitchen",
    auth_user_id: "auth-owner-001",
    restaurant_id: "rest-spicy-kitchen",
    email: "owner@spicykitchen.com",
    temp_password: false,
    role: "owner",
    is_active: true,
    created_at: new Date("2025-01-01").toISOString(),
  },
];

const SANDBOX_MENU_ITEMS: MenuItem[] = [
  {
    id: "item-001",
    restaurant_id: "rest-spicy-kitchen",
    name: "Paneer Butter Masala",
    description: "Rich and creamy curry made with fresh cottage cheese, tomato puree, and rich butter.",
    base_price: 280,
    category: "Main Course",
    is_available: true,
    sizes: [
      { name: "Half", price: 160 },
      { name: "Full", price: 280 },
    ],
    addons: [
      { name: "Extra Butter", price: 30 },
      { name: "Extra Cheese", price: 40 },
    ],
    created_at: new Date("2025-01-01").toISOString(),
  },
  {
    id: "item-002",
    restaurant_id: "rest-spicy-kitchen",
    name: "Butter Chicken",
    description: "Tender roasted chicken simmered in a mildly spiced, velvety tomato-cream gravy.",
    base_price: 360,
    category: "Main Course",
    is_available: true,
    sizes: [
      { name: "Half", price: 210 },
      { name: "Full", price: 360 },
    ],
    addons: [{ name: "Extra Gravy", price: 50 }],
    created_at: new Date("2025-01-01").toISOString(),
  },
  {
    id: "item-003",
    restaurant_id: "rest-spicy-kitchen",
    name: "Crispy Corn & Pepper Tikki",
    description: "Golden fried sweet corn patties infused with fresh herbs and Indian chaat spice blend.",
    base_price: 180,
    category: "Starters",
    is_available: true,
    created_at: new Date("2025-01-01").toISOString(),
  },
  {
    id: "item-004",
    restaurant_id: "rest-spicy-kitchen",
    name: "Garlic Butter Naan",
    description: "Freshly baked clay oven flatbread brushed with garlic butter and fresh coriander.",
    base_price: 65,
    category: "Main Course",
    is_available: true,
    created_at: new Date("2025-01-01").toISOString(),
  },
  {
    id: "item-005",
    restaurant_id: "rest-spicy-kitchen",
    name: "Royal Veg Dum Biryani",
    description: "Long-grain basmati rice slow-cooked on dum with saffron, garden veggies, and fried onions.",
    base_price: 260,
    category: "Main Course",
    is_available: true,
    created_at: new Date("2025-01-01").toISOString(),
  },
  {
    id: "item-006",
    restaurant_id: "rest-spicy-kitchen",
    name: "Mango Lassi",
    description: "Creamy traditional yogurt smoothie prepared with sweet Alphonso mango puree.",
    base_price: 110,
    category: "Beverages",
    is_available: true,
    created_at: new Date("2025-01-01").toISOString(),
  },
  {
    id: "item-007",
    restaurant_id: "rest-spicy-kitchen",
    name: "Gulab Jamun (2 Pcs)",
    description: "Warm, melt-in-mouth milk dumplings steeped in fragrant green cardamom and saffron syrup.",
    base_price: 90,
    category: "Desserts",
    is_available: true,
    created_at: new Date("2025-01-01").toISOString(),
  },
];

const SANDBOX_ORDERS: Order[] = [
  {
    id: "ord-001",
    restaurant_id: "rest-spicy-kitchen",
    order_number: "ORD1001",
    order_type: "qr",
    table_number: "4",
    customer_name: "Rahul Verma",
    customer_phone: "9820011223",
    items: [
      {
        menu_item_id: "item-001",
        name: "Paneer Butter Masala",
        quantity: 1,
        base_price: 280,
        item_total: 280,
      },
      {
        menu_item_id: "item-004",
        name: "Garlic Butter Naan",
        quantity: 2,
        base_price: 65,
        item_total: 130,
      },
    ],
    subtotal: 410,
    tax: 20.5,
    total: 430.5,
    status: "preparing",
    payment_method: "UPI",
    payment_status: "paid",
    created_at: new Date(Date.now() - 15 * 60 * 1000).toISOString(),
  },
  {
    id: "ord-002",
    restaurant_id: "rest-spicy-kitchen",
    order_number: "ORD1002",
    order_type: "table",
    table_number: "2",
    customer_name: "Priya Sen",
    customer_phone: "9820033445",
    items: [
      {
        menu_item_id: "item-002",
        name: "Butter Chicken",
        quantity: 1,
        base_price: 360,
        item_total: 360,
      },
      {
        menu_item_id: "item-006",
        name: "Mango Lassi",
        quantity: 2,
        base_price: 110,
        item_total: 220,
      },
    ],
    subtotal: 580,
    tax: 29,
    total: 609,
    status: "ready",
    payment_method: "Cash",
    payment_status: "pending",
    created_at: new Date(Date.now() - 45 * 60 * 1000).toISOString(),
  },
];

const SANDBOX_REQUESTS: RegistrationRequest[] = [
  {
    id: "req-001",
    restaurant_name: "The Grand Biryani",
    owner_name: "Mohammed Ali",
    phone: "9871122334",
    email: "ali@grandbiryani.com",
    city: "Hyderabad",
    address: "Charminar Road, Hyderabad",
    restaurant_type: "Restaurant",
    heard_from: "Social Media",
    notes: "Looking to digitize our dine-in ordering and contactless menu for 20 tables.",
    status: "pending",
    created_at: new Date(Date.now() - 3 * 3600 * 1000).toISOString(),
  },
];

const getTableData = (table: string): any[] => {
  switch (table) {
    case "restaurants":
      return getStoredTable("restaurants", SANDBOX_RESTAURANTS);
    case "users":
      return getStoredTable("users", SANDBOX_USERS);
    case "menu_items":
      return getStoredTable("menu_items", SANDBOX_MENU_ITEMS);
    case "orders":
      return getStoredTable("orders", SANDBOX_ORDERS);
    case "registration_requests":
      return getStoredTable("registration_requests", SANDBOX_REQUESTS);
    case "admin_users":
      return getStoredTable("admin_users", SANDBOX_ADMINS);
    default:
      return getStoredTable(table, []);
  }
};

const setTableData = (table: string, data: any[]) => {
  saveStoredTable(table, data);
};

// Query Builder for Sandbox Mock
class SandboxQueryBuilder {
  private tableName: string;
  private filters: ((item: any) => boolean)[] = [];
  private orderField?: string;
  private ascending = true;
  private isSingle = false;
  private countMode?: string;
  private isHeadOnly = false;
  private operation: "select" | "insert" | "update" | "delete" = "select";
  private insertData?: any[];
  private updateData?: any;

  constructor(tableName: string) {
    this.tableName = tableName;
  }

  select(_columns = "*", options?: { count?: string; head?: boolean }) {
    this.operation = "select";
    if (options?.count) this.countMode = options.count;
    if (options?.head) this.isHeadOnly = options.head;
    return this;
  }

  insert(items: any[]) {
    this.operation = "insert";
    this.insertData = items;
    return this;
  }

  update(updates: any) {
    this.operation = "update";
    this.updateData = updates;
    return this;
  }

  delete() {
    this.operation = "delete";
    return this;
  }

  eq(field: string, value: any) {
    this.filters.push((item) => {
      const itemVal = item[field];
      if (typeof value === "string" && typeof itemVal === "string") {
        return itemVal.toLowerCase() === value.toLowerCase();
      }
      return itemVal === value;
    });
    return this;
  }

  gte(field: string, value: any) {
    this.filters.push((item) => {
      const val = item[field];
      if (typeof val === "string" && typeof value === "string") {
        return new Date(val).getTime() >= new Date(value).getTime();
      }
      return val >= value;
    });
    return this;
  }

  lte(field: string, value: any) {
    this.filters.push((item) => {
      const val = item[field];
      if (typeof val === "string" && typeof value === "string") {
        return new Date(val).getTime() <= new Date(value).getTime();
      }
      return val <= value;
    });
    return this;
  }

  in(field: string, values: any[]) {
    this.filters.push((item) => values.includes(item[field]));
    return this;
  }

  or(filterStr: string) {
    // Basic parser for or filters like 'id.eq.val,email.eq.val'
    const parts = filterStr.split(",");
    this.filters.push((item) => {
      return parts.some((p) => {
        const [k, op, v] = p.split(".");
        if (op === "eq" && k && v) {
          return String(item[k]).toLowerCase() === v.toLowerCase();
        }
        return false;
      });
    });
    return this;
  }

  order(field: string, options?: { ascending?: boolean }) {
    this.orderField = field;
    this.ascending = options?.ascending !== false;
    return this;
  }

  single() {
    this.isSingle = true;
    return this;
  }

  private async execute(): Promise<{ data: any; error: any; count?: number }> {
    let rows = getTableData(this.tableName);

    // Join restaurants for user queries if requested
    if (this.tableName === "users") {
      const restaurants = getTableData("restaurants");
      rows = rows.map((u) => ({
        ...u,
        restaurants: restaurants.find((r) => r.id === u.restaurant_id) || null,
      }));
    }

    if (this.operation === "insert" && this.insertData) {
      const inserted = this.insertData.map((item) => ({
        id: item.id || `gen-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
        created_at: item.created_at || new Date().toISOString(),
        updated_at: new Date().toISOString(),
        ...item,
      }));
      rows = [...inserted, ...rows];
      setTableData(this.tableName, rows);
      inserted.forEach((item) => notifyListeners(this.tableName, "INSERT", item));

      const res = this.isSingle ? inserted[0] : inserted;
      return { data: res, error: null };
    }

    if (this.operation === "update" && this.updateData) {
      let updatedCount = 0;
      let lastUpdated: any = null;
      rows = rows.map((item) => {
        const matches = this.filters.every((f) => f(item));
        if (matches) {
          updatedCount++;
          const updated = {
            ...item,
            ...this.updateData,
            updated_at: new Date().toISOString(),
          };
          lastUpdated = updated;
          notifyListeners(this.tableName, "UPDATE", updated);
          return updated;
        }
        return item;
      });
      setTableData(this.tableName, rows);
      return { data: this.isSingle ? lastUpdated : rows, error: null, count: updatedCount };
    }

    if (this.operation === "delete") {
      const remaining: any[] = [];
      const deleted: any[] = [];
      rows.forEach((item) => {
        const matches = this.filters.every((f) => f(item));
        if (matches) {
          deleted.push(item);
          notifyListeners(this.tableName, "DELETE", item);
        } else {
          remaining.push(item);
        }
      });
      setTableData(this.tableName, remaining);
      return { data: deleted, error: null, count: deleted.length };
    }

    // SELECT
    const result = rows.filter((item) => this.filters.every((fn) => fn(item)));

    if (this.orderField) {
      const f = this.orderField;
      result.sort((a, b) => {
        const va = a[f];
        const vb = b[f];
        if (va < vb) return this.ascending ? -1 : 1;
        if (va > vb) return this.ascending ? 1 : -1;
        return 0;
      });
    }

    const count = result.length;

    if (this.isHeadOnly) {
      return { data: null, error: null, count };
    }

    if (this.isSingle) {
      if (result.length === 0) {
        return { data: null, error: { message: "Row not found" } };
      }
      return { data: result[0], error: null };
    }

    return { data: result, error: null, count: this.countMode ? count : undefined };
  }

  then<TResult1 = any, TResult2 = never>(
    onfulfilled?: ((value: { data: any; error: any; count?: number }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: any) => TResult2 | PromiseLike<TResult2>) | null
  ): Promise<TResult1 | TResult2> {
    return this.execute().then(onfulfilled, onrejected);
  }
}

// Development Sandbox Client matching Supabase Auth API
class SandboxSupabaseClient {
  private currentSession: any = null;
  private authSubscribers = new Set<(event: string, session: any) => void>();

  constructor() {
    // Restore session if exists
    try {
      const saved = localStorage.getItem(`${STORAGE_PREFIX}session`);
      if (saved) {
        this.currentSession = JSON.parse(saved);
      }
    } catch (_e) {
      this.currentSession = null;
    }
  }

  auth = {
    signInWithPassword: async ({ email, password }: { email: string; password?: string }) => {
      const lowerEmail = email.trim().toLowerCase();
      
      // Check in admin_users
      const admins = getTableData("admin_users") as AdminUser[];
      const admin = admins.find((a) => a.email.toLowerCase() === lowerEmail);
      if (admin) {
        const session = {
          access_token: `sb-mock-token-admin-${Date.now()}`,
          user: {
            id: admin.auth_user_id || admin.id,
            email: admin.email,
            user_metadata: { role: "admin", name: admin.name },
          },
        };
        this.currentSession = session;
        localStorage.setItem(`${STORAGE_PREFIX}session`, JSON.stringify(session));
        this.authSubscribers.forEach((cb) => cb("SIGNED_IN", session));
        return { data: { user: session.user, session }, error: null };
      }

      // Check in users
      const users = getTableData("users") as User[];
      const user = users.find((u) => u.email.toLowerCase() === lowerEmail);
      if (user) {
        const session = {
          access_token: `sb-mock-token-user-${Date.now()}`,
          user: {
            id: user.auth_user_id || user.id,
            email: user.email,
            user_metadata: { role: user.role, restaurant_id: user.restaurant_id },
          },
        };
        this.currentSession = session;
        localStorage.setItem(`${STORAGE_PREFIX}session`, JSON.stringify(session));
        this.authSubscribers.forEach((cb) => cb("SIGNED_IN", session));
        return { data: { user: session.user, session }, error: null };
      }

      // If user doesn't exist but has valid demo format, create standard demo session
      if (password && password.length >= 6) {
        return {
          data: { user: null, session: null },
          error: { message: "Invalid email or password" },
        };
      }

      return {
        data: { user: null, session: null },
        error: { message: "Invalid email or password" },
      };
    },

    signUp: async ({ email }: { email: string; password?: string }) => {
      const session = {
        access_token: `sb-mock-token-${Date.now()}`,
        user: {
          id: `auth-${Date.now()}`,
          email: email.trim().toLowerCase(),
        },
      };
      this.currentSession = session;
      localStorage.setItem(`${STORAGE_PREFIX}session`, JSON.stringify(session));
      this.authSubscribers.forEach((cb) => cb("SIGNED_IN", session));
      return { data: { user: session.user, session }, error: null };
    },

    signOut: async () => {
      this.currentSession = null;
      localStorage.removeItem(`${STORAGE_PREFIX}session`);
      this.authSubscribers.forEach((cb) => cb("SIGNED_OUT", null));
      return { error: null };
    },

    getSession: async () => {
      return { data: { session: this.currentSession }, error: null };
    },

    onAuthStateChange: (callback: (event: string, session: any) => void) => {
      this.authSubscribers.add(callback);
      return {
        data: {
          subscription: {
            unsubscribe: () => {
              this.authSubscribers.delete(callback);
            },
          },
        },
      };
    },
  };

  from(tableName: string) {
    return new SandboxQueryBuilder(tableName);
  }

  channel(_channelName: string) {
    return {
      on(
        _eventType: string,
        filter: { table: string; filter?: string },
        callback: () => void
      ) {
        const table = filter.table;
        if (!listeners.has(table)) {
          listeners.set(table, new Set());
        }
        const handler: Listener = () => {
          callback();
        };
        listeners.get(table)!.add(handler);

        return {
          subscribe() {
            return {
              unsubscribe() {
                listeners.get(table)?.delete(handler);
              },
            };
          },
        };
      },
      subscribe() {
        return {
          unsubscribe() {
            // no-op
          },
        };
      },
    };
  }

  async rpc(funcName: string, args: any = {}) {
    // SECURE SERVER-SIDE ORDER CREATION (Mirrors 001_multi_tenant_security.sql)
    if (funcName === "create_order_secure") {
      const {
        p_restaurant_id,
        p_order_type,
        p_table_number,
        p_customer_name,
        p_customer_phone,
        p_items,
        p_customer_notes,
      } = args;

      // 1. Validate restaurant
      const restaurants = getTableData("restaurants") as Restaurant[];
      const restaurant = restaurants.find(
        (r) => r.id === p_restaurant_id && r.is_active && r.status === "active"
      );

      if (!restaurant) {
        return {
          data: { success: false, error: "Restaurant is inactive or not found" },
          error: null,
        };
      }

      // 2. Validate items and verify prices against menu_items table
      const menuItems = getTableData("menu_items") as MenuItem[];
      let subtotal = 0;
      const verifiedItems: OrderItem[] = [];

      for (const itemInput of p_items || []) {
        const dbItem = menuItems.find(
          (m) => m.id === itemInput.menu_item_id && m.restaurant_id === p_restaurant_id
        );

        if (!dbItem) {
          return {
            data: { success: false, error: `Menu item ${itemInput.menu_item_id} not found` },
            error: null,
          };
        }

        if (!dbItem.is_available) {
          return {
            data: { success: false, error: `"${dbItem.name}" is currently sold out` },
            error: null,
          };
        }

        const qty = Number(itemInput.quantity) || 1;
        let itemPrice = Number(dbItem.base_price) || 0;

        // Verify size price against stored database item
        if (itemInput.selected_size?.name && dbItem.sizes) {
          const matchSize = dbItem.sizes.find((s) => s.name === itemInput.selected_size.name);
          if (matchSize) itemPrice = matchSize.price;
        }

        // Verify addons price against stored database item
        let addonsTotal = 0;
        if (itemInput.selected_addons && dbItem.addons) {
          for (const addon of itemInput.selected_addons) {
            const matchAddon = dbItem.addons.find((a) => a.name === addon.name);
            if (matchAddon) addonsTotal += matchAddon.price;
          }
        }

        const itemTotal = (itemPrice + addonsTotal) * qty;
        subtotal += itemTotal;

        verifiedItems.push({
          menu_item_id: dbItem.id,
          name: dbItem.name,
          quantity: qty,
          base_price: itemPrice,
          selected_size: itemInput.selected_size,
          selected_addons: itemInput.selected_addons || [],
          item_total: itemTotal,
          special_instructions: itemInput.special_instructions,
        });
      }

      const tax = Math.round(subtotal * 0.05 * 100) / 100;
      const total = subtotal + tax;
      const orderId = `ord-${Date.now()}`;
      const orderNumber = `ORD${Date.now().toString().slice(-6)}`;

      const newOrder: Order = {
        id: orderId,
        restaurant_id: p_restaurant_id,
        order_number: orderNumber,
        order_type: p_order_type || "qr",
        table_number: p_table_number,
        customer_name: p_customer_name,
        customer_phone: p_customer_phone,
        items: verifiedItems,
        subtotal,
        tax,
        total,
        status: "pending",
        customer_notes: p_customer_notes,
        created_at: new Date().toISOString(),
      };

      const orders = getTableData("orders");
      setTableData("orders", [newOrder, ...orders]);
      notifyListeners("orders", "INSERT", newOrder);

      return {
        data: {
          success: true,
          order_id: orderId,
          order_number: orderNumber,
          subtotal,
          tax,
          total,
        },
        error: null,
      };
    }

    // Safe customer order tracking RPC
    if (funcName === "get_customer_order_status") {
      const orders = getTableData("orders") as Order[];
      const order = orders.find((o) => o.id === args.p_order_id);
      if (!order) {
        return { data: { success: false, error: "Order not found" }, error: null };
      }
      return {
        data: {
          success: true,
          order_id: order.id,
          order_number: order.order_number,
          status: order.status,
          order_type: order.order_type,
          table_number: order.table_number,
          subtotal: order.subtotal,
          tax: order.tax,
          total: order.total,
          items: order.items,
          created_at: order.created_at,
          accepted_at: order.accepted_at,
          preparing_at: order.preparing_at,
          ready_at: order.ready_at,
          completed_at: order.completed_at,
        },
        error: null,
      };
    }

    if (funcName === "admin_create_restaurant") {
      const {
        p_request_id,
        p_restaurant_name,
        p_slug,
        p_owner_name,
        p_phone,
        p_email,
        p_city,
        p_address,
        p_subscription_plan,
        p_internal_notes,
      } = args;

      const restId = `rest-${Date.now()}`;
      const userId = `user-${Date.now()}`;

      const newRestaurant: Restaurant = {
        id: restId,
        registration_request_id: p_request_id,
        name: p_restaurant_name,
        slug: p_slug,
        owner_name: p_owner_name,
        phone: p_phone,
        email: p_email,
        city: p_city,
        address: p_address,
        subscription_plan: p_subscription_plan || "starter",
        status: "active",
        is_active: true,
        internal_notes: p_internal_notes,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };

      const newUser: User = {
        id: userId,
        auth_user_id: `auth-${userId}`,
        restaurant_id: restId,
        email: p_email,
        temp_password: true,
        role: "owner",
        created_at: new Date().toISOString(),
      };

      const restaurants = getTableData("restaurants");
      setTableData("restaurants", [newRestaurant, ...restaurants]);
      notifyListeners("restaurants", "INSERT", newRestaurant);

      const users = getTableData("users");
      setTableData("users", [newUser, ...users]);

      const requests = getTableData("registration_requests");
      const updatedRequests = requests.map((req) => {
        if (req.id === p_request_id) {
          const updated = {
            ...req,
            status: "verified",
            contacted_at: new Date().toISOString(),
            internal_notes: p_internal_notes,
          };
          notifyListeners("registration_requests", "UPDATE", updated);
          return updated;
        }
        return req;
      });
      setTableData("registration_requests", updatedRequests);

      return {
        data: [
          {
            restaurant_id: restId,
            user_id: userId,
            success: true,
            message: "Restaurant created successfully",
          },
        ],
        error: null,
      };
    }

    if (funcName === "admin_toggle_restaurant_status") {
      const { p_restaurant_id, p_is_active, p_block_reason } = args;
      const restaurants = getTableData("restaurants") as Restaurant[];
      const updated = restaurants.map((r) => {
        if (r.id === p_restaurant_id) {
          const u = {
            ...r,
            is_active: p_is_active,
            status: (p_is_active ? "active" : "blocked") as "active" | "blocked",
            block_reason: p_block_reason || null,
          };
          notifyListeners("restaurants", "UPDATE", u);
          return u;
        }
        return r;
      });
      setTableData("restaurants", updated);
      return { data: true, error: null };
    }

    if (funcName === "admin_reject_request") {
      const { p_request_id, p_rejection_reason } = args;
      const requests = getTableData("registration_requests");
      const updated = requests.map((req) => {
        if (req.id === p_request_id) {
          const u = {
            ...req,
            status: "rejected",
            rejection_reason: p_rejection_reason,
          };
          notifyListeners("registration_requests", "UPDATE", u);
          return u;
        }
        return req;
      });
      setTableData("registration_requests", updated);
      return { data: true, error: null };
    }

    return { data: null, error: { message: `RPC ${funcName} not recognized` } };
  }
}

// ============================================================================
// Client Factory
// ============================================================================

let instance: any;

if (isRealSupabaseConfigured()) {
  try {
    instance = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        autoRefreshToken: true,
        persistSession: true,
        detectSessionInUrl: true,
      },
    });
    console.info("[FoodOrder] Connected to live Supabase backend.");
  } catch (err) {
    if (isProduction) {
      console.error("[FoodOrder] CRITICAL: Live Supabase initialization failed in production:", err);
      instance = new UnconfiguredProductionClient();
    } else {
      console.warn("[FoodOrder] Supabase initialization failed in dev, starting sandbox:", err);
      instance = new SandboxSupabaseClient();
    }
  }
} else {
  if (isProduction) {
    console.error("[FoodOrder] CRITICAL: Missing Supabase production credentials. Mock fallback is disabled in production.");
    instance = new UnconfiguredProductionClient();
  } else {
    console.info("[FoodOrder] Running in local development sandbox mode. To connect live Supabase, configure VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.");
    instance = new SandboxSupabaseClient();
  }
}

export const supabase: SupabaseClient | any = instance;
