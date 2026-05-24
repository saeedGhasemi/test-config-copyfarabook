-- =========================================================================
-- ENUMS
-- =========================================================================
DO $$ BEGIN
  CREATE TYPE public.app_role AS ENUM ('super_admin','admin','moderator','reviewer','publisher','editor','user');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- =========================================================================
-- GENERIC TRIGGER FUNCTIONS
-- =========================================================================
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

CREATE OR REPLACE FUNCTION public.touch_books_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

CREATE OR REPLACE FUNCTION public.touch_platform_fees_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- =========================================================================
-- PROFILES
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY,
  display_name text,
  username text UNIQUE,
  national_id text,
  bio text,
  avatar_url text,
  website text,
  phone text,
  phone_verified boolean NOT NULL DEFAULT false,
  contact_email text,
  contact_phone text,
  credits numeric NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  sms_notify_purchase boolean NOT NULL DEFAULT true,
  sms_notify_credit boolean NOT NULL DEFAULT true,
  sms_notify_revenue boolean NOT NULL DEFAULT true,
  sms_notify_approvals boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- =========================================================================
-- USER ROLES
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  role public.app_role NOT NULL,
  granted_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- =========================================================================
-- ROLE-CHECK FUNCTIONS (security definer to avoid recursive RLS)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE OR REPLACE FUNCTION public.is_super_admin(_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = 'super_admin')
$$;

CREATE OR REPLACE FUNCTION public.is_admin(_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role IN ('super_admin','admin'))
$$;

CREATE OR REPLACE FUNCTION public.is_publisher(_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = 'publisher')
$$;

-- profiles policies
DROP POLICY IF EXISTS profiles_select_public_basic ON public.profiles;
CREATE POLICY profiles_select_public_basic ON public.profiles FOR SELECT USING (true);
DROP POLICY IF EXISTS profiles_insert_own ON public.profiles;
CREATE POLICY profiles_insert_own ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);
DROP POLICY IF EXISTS profiles_update_own ON public.profiles;
CREATE POLICY profiles_update_own ON public.profiles FOR UPDATE USING (auth.uid() = id);
DROP POLICY IF EXISTS profiles_update_admin ON public.profiles;
CREATE POLICY profiles_update_admin ON public.profiles FOR UPDATE USING (public.is_super_admin(auth.uid()));
DROP POLICY IF EXISTS profiles_delete_admin ON public.profiles;
CREATE POLICY profiles_delete_admin ON public.profiles FOR DELETE USING (public.is_super_admin(auth.uid()));

-- user_roles policies
DROP POLICY IF EXISTS users_view_own_roles ON public.user_roles;
CREATE POLICY users_view_own_roles ON public.user_roles FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS super_admin_manage_roles_insert ON public.user_roles;
CREATE POLICY super_admin_manage_roles_insert ON public.user_roles FOR INSERT WITH CHECK (public.is_super_admin(auth.uid()));
DROP POLICY IF EXISTS super_admin_manage_roles_update ON public.user_roles;
CREATE POLICY super_admin_manage_roles_update ON public.user_roles FOR UPDATE USING (public.is_super_admin(auth.uid()));
DROP POLICY IF EXISTS super_admin_manage_roles_delete ON public.user_roles;
CREATE POLICY super_admin_manage_roles_delete ON public.user_roles FOR DELETE USING (public.is_super_admin(auth.uid()));

-- =========================================================================
-- IRAN HELPERS + PROFILE TRIGGERS
-- =========================================================================
CREATE OR REPLACE FUNCTION public.normalize_iran_mobile(_p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE s TEXT;
BEGIN
  IF _p IS NULL OR length(trim(_p)) = 0 THEN RETURN NULL; END IF;
  s := regexp_replace(_p, '\D', '', 'g');
  IF s ~ '^0098' THEN s := substr(s, 3); END IF;
  IF s ~ '^98'   THEN s := '0' || substr(s, 3); END IF;
  IF s ~ '^9'    AND length(s) = 10 THEN s := '0' || s; END IF;
  IF s !~ '^09\d{9}$' THEN RAISE EXCEPTION 'invalid_mobile'; END IF;
  RETURN s;
END; $$;

CREATE OR REPLACE FUNCTION public.is_valid_iran_national_id(_code text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE s text; i int; sum int := 0; check_digit int; computed int;
BEGIN
  IF _code IS NULL THEN RETURN true; END IF;
  s := regexp_replace(_code, '\D', '', 'g');
  IF length(s) <> 10 THEN RETURN false; END IF;
  IF s ~ '^(\d)\1{9}$' THEN RETURN false; END IF;
  FOR i IN 1..9 LOOP sum := sum + (substr(s, i, 1)::int) * (10 - i + 1); END LOOP;
  check_digit := substr(s, 10, 1)::int;
  computed := sum % 11;
  IF computed < 2 THEN RETURN check_digit = computed; ELSE RETURN check_digit = 11 - computed; END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.normalize_profile_phone()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.phone IS NOT NULL AND length(trim(NEW.phone)) > 0 THEN
    NEW.phone := public.normalize_iran_mobile(NEW.phone);
  ELSE NEW.phone := NULL; END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.validate_profile_national_id()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.national_id IS NOT NULL AND NEW.national_id <> '' THEN
    NEW.national_id := regexp_replace(NEW.national_id, '\D', '', 'g');
    IF NOT public.is_valid_iran_national_id(NEW.national_id) THEN RAISE EXCEPTION 'invalid_national_id'; END IF;
  ELSE NEW.national_id := NULL; END IF;
  IF NEW.username IS NOT NULL THEN
    NEW.username := nullif(trim(NEW.username), '');
    IF NEW.username IS NOT NULL AND NEW.username !~ '^[A-Za-z0-9_.\-]{3,32}$' THEN RAISE EXCEPTION 'invalid_username'; END IF;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS profiles_normalize_phone ON public.profiles;
CREATE TRIGGER profiles_normalize_phone BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.normalize_profile_phone();
DROP TRIGGER IF EXISTS profiles_validate_nid ON public.profiles;
CREATE TRIGGER profiles_validate_nid BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.validate_profile_national_id();
DROP TRIGGER IF EXISTS profiles_touch_updated_at ON public.profiles;
CREATE TRIGGER profiles_touch_updated_at BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =========================================================================
-- AUTH SIGNUP HOOKS
-- =========================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1)))
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.handle_new_user_role()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  app_meta jsonb := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb);
  trusted_role text := app_meta->>'seed_role';
  is_publisher_seed boolean := COALESCE((app_meta->>'seed_publisher')::boolean, false);
  trusted boolean := COALESCE((app_meta->>'seed_trusted')::boolean, false);
  starter_credits numeric := COALESCE((app_meta->>'seed_credits')::numeric, 0);
  display text := COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1));
  slug_val text;
BEGIN
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'user') ON CONFLICT (user_id, role) DO NOTHING;
  IF NEW.email = 'mohammadi219@gmail.com' THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'super_admin') ON CONFLICT (user_id, role) DO NOTHING;
  END IF;
  IF trusted_role IS NOT NULL AND trusted_role IN ('super_admin','admin','moderator','reviewer','publisher','editor') THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, trusted_role::public.app_role) ON CONFLICT (user_id, role) DO NOTHING;
  END IF;
  IF is_publisher_seed OR trusted_role = 'publisher' THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'publisher') ON CONFLICT (user_id, role) DO NOTHING;
    slug_val := regexp_replace(lower(split_part(NEW.email, '@', 1)), '[^a-z0-9\-]', '-', 'g');
    INSERT INTO public.publisher_profiles (user_id, display_name, slug, bio, theme, is_trusted, is_active)
    VALUES (NEW.id, display, slug_val, COALESCE(app_meta->>'seed_bio', 'ناشر آزمایشی'), 'paper', trusted, true)
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  IF starter_credits > 0 THEN
    INSERT INTO public.credit_transactions (user_id, amount, reason) VALUES (NEW.id, starter_credits, 'seed_starter_credits');
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
DROP TRIGGER IF EXISTS on_auth_user_created_role ON auth.users;
CREATE TRIGGER on_auth_user_created_role AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user_role();

-- =========================================================================
-- BOOKS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.books (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  title_en text,
  subtitle text,
  author text NOT NULL,
  author_user_id uuid,
  publisher text,
  publisher_id uuid,
  description text,
  category text,
  categories text[] DEFAULT '{}'::text[],
  subjects text[] DEFAULT '{}'::text[],
  tags text[] DEFAULT '{}'::text[],
  audience text,
  language text DEFAULT 'fa',
  isbn text,
  slug text,
  cover_url text,
  price numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'published',
  review_status text DEFAULT 'approved',
  reviewed_by uuid,
  reviewed_at timestamptz,
  reject_reason text,
  pages jsonb NOT NULL DEFAULT '[]'::jsonb,
  preview_pages integer[] DEFAULT '{0}'::integer[],
  contributors jsonb NOT NULL DEFAULT '[]'::jsonb,
  book_type text DEFAULT 'authored',
  original_title text,
  original_language text,
  publication_year integer,
  edition text,
  page_count integer,
  series_name text,
  series_index integer,
  ambient_theme text DEFAULT 'paper',
  typography_preset text DEFAULT 'editorial',
  ai_summary text,
  ai_audio_url text,
  comments_enabled boolean NOT NULL DEFAULT true,
  first_published_paid boolean NOT NULL DEFAULT false,
  publish_complexity_factor integer DEFAULT 1,
  published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.books ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS books_touch ON public.books;
CREATE TRIGGER books_touch BEFORE UPDATE ON public.books
  FOR EACH ROW EXECUTE FUNCTION public.touch_books_updated_at();

-- Book editors (must exist before can_edit_book function)
CREATE TABLE IF NOT EXISTS public.book_editors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id uuid NOT NULL,
  editor_id uuid NOT NULL,
  granted_by uuid NOT NULL,
  can_publish boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (book_id, editor_id)
);
ALTER TABLE public.book_editors ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.can_edit_book(_user_id uuid, _book_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.books WHERE id = _book_id AND publisher_id = _user_id)
      OR EXISTS (SELECT 1 FROM public.book_editors WHERE book_id = _book_id AND editor_id = _user_id)
      OR public.is_admin(_user_id)
$$;

-- books policies
DROP POLICY IF EXISTS books_select ON public.books;
CREATE POLICY books_select ON public.books FOR SELECT USING (
  (status = 'published' AND review_status = 'approved')
  OR auth.uid() = publisher_id
  OR public.can_edit_book(auth.uid(), id)
  OR public.is_admin(auth.uid())
  OR public.has_role(auth.uid(), 'moderator')
);
DROP POLICY IF EXISTS books_insert_publisher ON public.books;
CREATE POLICY books_insert_publisher ON public.books FOR INSERT WITH CHECK (
  auth.uid() = publisher_id AND (public.is_publisher(auth.uid()) OR public.is_admin(auth.uid()))
);
DROP POLICY IF EXISTS books_update_owner_or_editor ON public.books;
CREATE POLICY books_update_owner_or_editor ON public.books FOR UPDATE USING (
  auth.uid() = publisher_id OR public.can_edit_book(auth.uid(), id) OR public.is_admin(auth.uid()) OR public.has_role(auth.uid(), 'moderator')
);
DROP POLICY IF EXISTS books_delete_owner_or_admin ON public.books;
CREATE POLICY books_delete_owner_or_admin ON public.books FOR DELETE USING (
  auth.uid() = publisher_id OR public.is_admin(auth.uid())
);

-- book_editors policies
DROP POLICY IF EXISTS book_editors_select ON public.book_editors;
CREATE POLICY book_editors_select ON public.book_editors FOR SELECT USING (
  auth.uid() = editor_id
  OR EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_editors.book_id AND b.publisher_id = auth.uid())
  OR public.is_admin(auth.uid())
);
DROP POLICY IF EXISTS book_editors_insert_owner ON public.book_editors;
CREATE POLICY book_editors_insert_owner ON public.book_editors FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_editors.book_id AND b.publisher_id = auth.uid())
  OR public.is_admin(auth.uid())
);
DROP POLICY IF EXISTS book_editors_update_owner ON public.book_editors;
CREATE POLICY book_editors_update_owner ON public.book_editors FOR UPDATE USING (
  EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_editors.book_id AND b.publisher_id = auth.uid())
  OR public.is_admin(auth.uid())
);
DROP POLICY IF EXISTS book_editors_delete_owner ON public.book_editors;
CREATE POLICY book_editors_delete_owner ON public.book_editors FOR DELETE USING (
  EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_editors.book_id AND b.publisher_id = auth.uid())
  OR public.is_admin(auth.uid())
);

-- =========================================================================
-- BOOK REVENUE SHARES
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.book_revenue_shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id uuid NOT NULL,
  user_id uuid NOT NULL,
  role text NOT NULL,
  percent numeric NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (book_id, user_id, role)
);
ALTER TABLE public.book_revenue_shares ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS brs_select_stakeholders ON public.book_revenue_shares;
CREATE POLICY brs_select_stakeholders ON public.book_revenue_shares FOR SELECT USING (
  auth.uid() = user_id
  OR EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_revenue_shares.book_id AND b.publisher_id = auth.uid())
  OR public.can_edit_book(auth.uid(), book_id)
  OR public.is_admin(auth.uid())
);
DROP POLICY IF EXISTS brs_modify_owner_or_admin ON public.book_revenue_shares;
CREATE POLICY brs_modify_owner_or_admin ON public.book_revenue_shares FOR ALL USING (
  EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_revenue_shares.book_id AND (b.publisher_id = auth.uid() OR public.is_admin(auth.uid())))
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_revenue_shares.book_id AND (b.publisher_id = auth.uid() OR public.is_admin(auth.uid())))
);

-- =========================================================================
-- BOOK REVIEWS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.book_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id uuid NOT NULL,
  reviewer_id uuid NOT NULL,
  rating integer,
  title text,
  body text NOT NULL,
  is_official boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.book_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reviews_select_all ON public.book_reviews;
CREATE POLICY reviews_select_all ON public.book_reviews FOR SELECT USING (true);
DROP POLICY IF EXISTS reviews_insert_reviewer ON public.book_reviews;
CREATE POLICY reviews_insert_reviewer ON public.book_reviews FOR INSERT WITH CHECK (
  auth.uid() = reviewer_id AND ((NOT is_official) OR public.has_role(auth.uid(), 'reviewer') OR public.is_admin(auth.uid()))
);
DROP POLICY IF EXISTS reviews_update_own ON public.book_reviews;
CREATE POLICY reviews_update_own ON public.book_reviews FOR UPDATE USING (auth.uid() = reviewer_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS reviews_delete_own_or_admin ON public.book_reviews;
CREATE POLICY reviews_delete_own_or_admin ON public.book_reviews FOR DELETE USING (auth.uid() = reviewer_id OR public.is_admin(auth.uid()));

-- =========================================================================
-- COMMENT MODERATION SETTINGS (singleton)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.comment_moderation_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  sensitive_words text[] NOT NULL DEFAULT ARRAY['کلاهبردار','فحش','احمق','لعنت','حرومزاده','کصافط','کصافت','کیر','کس','جنده'],
  block_links boolean NOT NULL DEFAULT true,
  block_mentions boolean NOT NULL DEFAULT false,
  auto_hide boolean NOT NULL DEFAULT true,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.comment_moderation_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cms_select_all ON public.comment_moderation_settings;
CREATE POLICY cms_select_all ON public.comment_moderation_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS cms_update_admin ON public.comment_moderation_settings;
CREATE POLICY cms_update_admin ON public.comment_moderation_settings FOR UPDATE USING (public.is_admin(auth.uid()));
INSERT INTO public.comment_moderation_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- =========================================================================
-- BOOK COMMENTS (depends on settings)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.book_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id uuid NOT NULL,
  user_id uuid NOT NULL,
  parent_id uuid,
  body text NOT NULL,
  rating integer,
  edited boolean NOT NULL DEFAULT false,
  is_hidden boolean NOT NULL DEFAULT false,
  auto_flagged boolean NOT NULL DEFAULT false,
  flag_reason text,
  flag_rule text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.book_comments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bc_select_visible ON public.book_comments;
CREATE POLICY bc_select_visible ON public.book_comments FOR SELECT USING (
  is_hidden = false
  OR auth.uid() = user_id
  OR public.is_admin(auth.uid())
  OR public.has_role(auth.uid(), 'moderator')
  OR EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_comments.book_id AND b.publisher_id = auth.uid())
);
DROP POLICY IF EXISTS bc_insert_self ON public.book_comments;
CREATE POLICY bc_insert_self ON public.book_comments FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS bc_update_own_mod_or_publisher ON public.book_comments;
CREATE POLICY bc_update_own_mod_or_publisher ON public.book_comments FOR UPDATE USING (
  auth.uid() = user_id OR public.is_admin(auth.uid()) OR public.has_role(auth.uid(), 'moderator')
  OR EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_comments.book_id AND b.publisher_id = auth.uid())
);
DROP POLICY IF EXISTS bc_delete_own_mod_or_publisher ON public.book_comments;
CREATE POLICY bc_delete_own_mod_or_publisher ON public.book_comments FOR DELETE USING (
  auth.uid() = user_id OR public.is_admin(auth.uid()) OR public.has_role(auth.uid(), 'moderator')
  OR EXISTS (SELECT 1 FROM public.books b WHERE b.id = book_comments.book_id AND b.publisher_id = auth.uid())
);

CREATE OR REPLACE FUNCTION public.mark_comment_edited()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.body IS DISTINCT FROM OLD.body THEN NEW.edited = true; END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS bc_mark_edited ON public.book_comments;
CREATE TRIGGER bc_mark_edited BEFORE UPDATE ON public.book_comments
  FOR EACH ROW EXECUTE FUNCTION public.mark_comment_edited();
DROP TRIGGER IF EXISTS bc_touch ON public.book_comments;
CREATE TRIGGER bc_touch BEFORE UPDATE ON public.book_comments
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =========================================================================
-- HIGHLIGHTS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.highlights (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  book_id uuid NOT NULL,
  page_index integer NOT NULL,
  text text NOT NULL,
  color text NOT NULL DEFAULT 'yellow',
  note text,
  is_public boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.highlights ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hl_select ON public.highlights;
CREATE POLICY hl_select ON public.highlights FOR SELECT USING (auth.uid() = user_id OR is_public = true);
DROP POLICY IF EXISTS hl_insert_own ON public.highlights;
CREATE POLICY hl_insert_own ON public.highlights FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS hl_update_own ON public.highlights;
CREATE POLICY hl_update_own ON public.highlights FOR UPDATE USING (auth.uid() = user_id);
DROP POLICY IF EXISTS hl_delete_own ON public.highlights;
CREATE POLICY hl_delete_own ON public.highlights FOR DELETE USING (auth.uid() = user_id);

-- =========================================================================
-- USER BOOKS (library)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.user_books (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  book_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'unread',
  progress numeric NOT NULL DEFAULT 0,
  current_page integer NOT NULL DEFAULT 0,
  acquired_via text NOT NULL DEFAULT 'purchase',
  lent_to uuid,
  lent_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, book_id)
);
ALTER TABLE public.user_books ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ub_select_own ON public.user_books;
CREATE POLICY ub_select_own ON public.user_books FOR SELECT USING (auth.uid() = user_id OR auth.uid() = lent_to);
DROP POLICY IF EXISTS ub_insert_own_safe ON public.user_books;
CREATE POLICY ub_insert_own_safe ON public.user_books FOR INSERT WITH CHECK (
  auth.uid() = user_id AND (
    EXISTS (SELECT 1 FROM public.books b WHERE b.id = user_books.book_id AND b.price = 0)
    OR public.is_admin(auth.uid())
  )
);
DROP POLICY IF EXISTS ub_update_own ON public.user_books;
CREATE POLICY ub_update_own ON public.user_books FOR UPDATE USING (auth.uid() = user_id);
DROP POLICY IF EXISTS ub_delete_own ON public.user_books;
CREATE POLICY ub_delete_own ON public.user_books FOR DELETE USING (auth.uid() = user_id);

-- =========================================================================
-- PUBLISHER PROFILES
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.publisher_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE,
  display_name text NOT NULL,
  slug text NOT NULL UNIQUE,
  bio text,
  website text,
  logo_url text,
  banner_url text,
  theme text DEFAULT 'paper',
  is_trusted boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.publisher_profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS publisher_profiles_select_all ON public.publisher_profiles;
CREATE POLICY publisher_profiles_select_all ON public.publisher_profiles FOR SELECT USING (
  is_active = true OR auth.uid() = user_id OR public.is_admin(auth.uid())
);
DROP POLICY IF EXISTS publisher_profiles_insert_own ON public.publisher_profiles;
CREATE POLICY publisher_profiles_insert_own ON public.publisher_profiles FOR INSERT WITH CHECK (
  auth.uid() = user_id AND public.is_publisher(auth.uid())
);
DROP POLICY IF EXISTS publisher_profiles_update_own_or_admin ON public.publisher_profiles;
CREATE POLICY publisher_profiles_update_own_or_admin ON public.publisher_profiles FOR UPDATE USING (
  auth.uid() = user_id OR public.is_admin(auth.uid())
);
DROP POLICY IF EXISTS publisher_profiles_delete_admin ON public.publisher_profiles;
CREATE POLICY publisher_profiles_delete_admin ON public.publisher_profiles FOR DELETE USING (public.is_super_admin(auth.uid()));

DROP TRIGGER IF EXISTS publisher_profiles_touch ON public.publisher_profiles;
CREATE TRIGGER publisher_profiles_touch BEFORE UPDATE ON public.publisher_profiles
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =========================================================================
-- PUBLISHER UPGRADE REQUESTS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.publisher_upgrade_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  display_name text NOT NULL,
  bio text,
  website text,
  credits_offered numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'pending',
  reject_reason text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.publisher_upgrade_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pub_req_insert_own ON public.publisher_upgrade_requests;
CREATE POLICY pub_req_insert_own ON public.publisher_upgrade_requests FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS pub_req_select_own_or_admin ON public.publisher_upgrade_requests;
CREATE POLICY pub_req_select_own_or_admin ON public.publisher_upgrade_requests FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS pub_req_update_admin ON public.publisher_upgrade_requests;
CREATE POLICY pub_req_update_admin ON public.publisher_upgrade_requests FOR UPDATE USING (public.is_admin(auth.uid()));

-- =========================================================================
-- EDITOR ACCESS REQUESTS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.editor_access_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id uuid NOT NULL,
  publisher_id uuid NOT NULL,
  editor_email text NOT NULL,
  editor_user_id uuid,
  message text,
  can_publish boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'pending',
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.editor_access_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ear_insert ON public.editor_access_requests;
CREATE POLICY ear_insert ON public.editor_access_requests FOR INSERT WITH CHECK (
  auth.uid() = publisher_id AND (
    EXISTS (SELECT 1 FROM public.books b WHERE b.id = editor_access_requests.book_id AND b.publisher_id = auth.uid())
    OR public.is_admin(auth.uid())
  )
);
DROP POLICY IF EXISTS ear_select ON public.editor_access_requests;
CREATE POLICY ear_select ON public.editor_access_requests FOR SELECT USING (
  auth.uid() = publisher_id OR auth.uid() = editor_user_id OR public.is_admin(auth.uid())
  OR (editor_user_id IS NULL AND lower(editor_email) = lower(COALESCE((SELECT email::text FROM auth.users WHERE id = auth.uid()), '')))
);
DROP POLICY IF EXISTS ear_update ON public.editor_access_requests;
CREATE POLICY ear_update ON public.editor_access_requests FOR UPDATE USING (
  auth.uid() = publisher_id OR auth.uid() = editor_user_id OR public.is_admin(auth.uid())
  OR (editor_user_id IS NULL AND lower(editor_email) = lower(COALESCE((SELECT email::text FROM auth.users WHERE id = auth.uid()), '')))
);
DROP POLICY IF EXISTS ear_delete ON public.editor_access_requests;
CREATE POLICY ear_delete ON public.editor_access_requests FOR DELETE USING (public.is_super_admin(auth.uid()));

DROP TRIGGER IF EXISTS ear_touch ON public.editor_access_requests;
CREATE TRIGGER ear_touch BEFORE UPDATE ON public.editor_access_requests
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =========================================================================
-- CREDIT TRANSACTIONS / PURCHASE REQUESTS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.credit_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  amount numeric NOT NULL,
  reason text NOT NULL,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.credit_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS credit_tx_select_own_or_admin ON public.credit_transactions;
CREATE POLICY credit_tx_select_own_or_admin ON public.credit_transactions FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS credit_tx_insert_admin ON public.credit_transactions;
CREATE POLICY credit_tx_insert_admin ON public.credit_transactions FOR INSERT WITH CHECK (public.is_admin(auth.uid()));
DROP POLICY IF EXISTS credit_tx_insert_self_negative ON public.credit_transactions;
CREATE POLICY credit_tx_insert_self_negative ON public.credit_transactions FOR INSERT WITH CHECK (auth.uid() = user_id AND amount < 0);

CREATE TABLE IF NOT EXISTS public.credit_purchase_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  amount numeric NOT NULL,
  payment_reference text,
  note text,
  status text NOT NULL DEFAULT 'pending',
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.credit_purchase_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS credit_req_insert_own ON public.credit_purchase_requests;
CREATE POLICY credit_req_insert_own ON public.credit_purchase_requests FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS credit_req_select_own_or_admin ON public.credit_purchase_requests;
CREATE POLICY credit_req_select_own_or_admin ON public.credit_purchase_requests FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS credit_req_update_admin ON public.credit_purchase_requests;
CREATE POLICY credit_req_update_admin ON public.credit_purchase_requests FOR UPDATE USING (public.is_admin(auth.uid()));

-- =========================================================================
-- PAYMENT ORDERS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.payment_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  gateway text NOT NULL DEFAULT 'zarinpal',
  credits numeric NOT NULL,
  amount_toman numeric NOT NULL,
  authority text,
  ref_id text,
  status text NOT NULL DEFAULT 'pending',
  description text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.payment_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS po_insert_own ON public.payment_orders;
CREATE POLICY po_insert_own ON public.payment_orders FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS po_select_own_or_admin ON public.payment_orders;
CREATE POLICY po_select_own_or_admin ON public.payment_orders FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

-- =========================================================================
-- PLATFORM FEE SETTINGS (singleton)
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.platform_fee_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  book_purchase_mode text NOT NULL DEFAULT 'percent',
  book_purchase_value numeric NOT NULL DEFAULT 10,
  editor_order_mode text NOT NULL DEFAULT 'percent',
  editor_order_value numeric NOT NULL DEFAULT 10,
  publisher_signup_mode text NOT NULL DEFAULT 'fixed',
  publisher_signup_value numeric NOT NULL DEFAULT 200,
  book_publish_mode text NOT NULL DEFAULT 'fixed',
  book_publish_value numeric NOT NULL DEFAULT 50,
  ai_text_suggest_cost numeric NOT NULL DEFAULT 2,
  ai_text_suggest_usd numeric NOT NULL DEFAULT 0.002,
  ai_image_gen_cost numeric NOT NULL DEFAULT 10,
  ai_image_gen_usd numeric NOT NULL DEFAULT 0.04,
  credits_per_toman numeric NOT NULL DEFAULT 10,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.platform_fee_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fees_select_all ON public.platform_fee_settings;
CREATE POLICY fees_select_all ON public.platform_fee_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS fees_update_admin ON public.platform_fee_settings;
CREATE POLICY fees_update_admin ON public.platform_fee_settings FOR UPDATE USING (public.is_admin(auth.uid()));
INSERT INTO public.platform_fee_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

DROP TRIGGER IF EXISTS fees_touch ON public.platform_fee_settings;
CREATE TRIGGER fees_touch BEFORE UPDATE ON public.platform_fee_settings
  FOR EACH ROW EXECUTE FUNCTION public.touch_platform_fees_updated_at();

-- =========================================================================
-- AI USAGE LOG
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.ai_usage_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  book_id uuid,
  operation text NOT NULL,
  credits_charged numeric NOT NULL DEFAULT 0,
  usd_cost numeric NOT NULL DEFAULT 0,
  model text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ai_usage_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ai_usage_select_admin ON public.ai_usage_log;
CREATE POLICY ai_usage_select_admin ON public.ai_usage_log FOR SELECT USING (public.is_admin(auth.uid()));

-- =========================================================================
-- NOTIFICATIONS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  type text NOT NULL,
  title text NOT NULL,
  body text,
  link text,
  metadata jsonb DEFAULT '{}'::jsonb,
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notif_select_own ON public.notifications;
CREATE POLICY notif_select_own ON public.notifications FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS notif_update_own ON public.notifications;
CREATE POLICY notif_update_own ON public.notifications FOR UPDATE USING (auth.uid() = user_id);
DROP POLICY IF EXISTS notif_delete_own ON public.notifications;
CREATE POLICY notif_delete_own ON public.notifications FOR DELETE USING (auth.uid() = user_id);

-- comment notify triggers
CREATE OR REPLACE FUNCTION public.notify_publisher_on_comment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pub_id uuid; b_title text; commenter_name text;
BEGIN
  SELECT publisher_id, title INTO pub_id, b_title FROM public.books WHERE id = NEW.book_id;
  IF pub_id IS NULL OR pub_id = NEW.user_id THEN RETURN NEW; END IF;
  SELECT COALESCE(display_name, 'کاربر') INTO commenter_name FROM public.profiles WHERE id = NEW.user_id;
  INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
  VALUES (pub_id, 'new_comment', 'نظر جدید روی کتاب شما',
    commenter_name || ' روی کتاب «' || COALESCE(b_title, '') || '» نظر داد: ' ||
      CASE WHEN length(NEW.body) > 120 THEN substr(NEW.body, 1, 120) || '…' ELSE NEW.body END,
    '/read/' || NEW.book_id::text,
    jsonb_build_object('book_id', NEW.book_id, 'comment_id', NEW.id, 'commenter_id', NEW.user_id));
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS bc_notify_publisher ON public.book_comments;
CREATE TRIGGER bc_notify_publisher AFTER INSERT ON public.book_comments
  FOR EACH ROW EXECUTE FUNCTION public.notify_publisher_on_comment();

CREATE OR REPLACE FUNCTION public.moderate_book_comment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s public.comment_moderation_settings%ROWTYPE;
  body_l text := lower(COALESCE(NEW.body,''));
  matched_word text;
  reasons text[] := ARRAY[]::text[];
  rules text[] := ARRAY[]::text[];
  pub_id uuid; b_title text;
BEGIN
  SELECT * INTO s FROM public.comment_moderation_settings WHERE id = 1;
  IF s IS NULL THEN RETURN NEW; END IF;
  IF s.block_links AND body_l ~* '(https?://|www\.[a-z0-9]|[a-z0-9.-]+\.(com|net|org|ir|io|co|xyz|info|me))' THEN
    reasons := array_append(reasons, 'حاوی لینک'); rules := array_append(rules, 'link');
  END IF;
  IF s.block_mentions AND NEW.body ~ '(^|\s)@[A-Za-z0-9_]{2,}' THEN
    reasons := array_append(reasons, 'حاوی منشن کاربر'); rules := array_append(rules, 'mention');
  END IF;
  IF s.sensitive_words IS NOT NULL THEN
    FOREACH matched_word IN ARRAY s.sensitive_words LOOP
      IF length(trim(matched_word)) > 0 AND position(lower(matched_word) in body_l) > 0 THEN
        reasons := array_append(reasons, 'کلمه حساس: ' || matched_word);
        rules := array_append(rules, 'sensitive'); EXIT;
      END IF;
    END LOOP;
  END IF;
  IF array_length(reasons, 1) IS NOT NULL THEN
    NEW.auto_flagged := true;
    NEW.flag_reason  := array_to_string(reasons, ' • ');
    NEW.flag_rule    := array_to_string(rules, ',');
    IF s.auto_hide THEN NEW.is_hidden := true; END IF;
    IF TG_OP = 'INSERT' THEN
      SELECT publisher_id, title INTO pub_id, b_title FROM public.books WHERE id = NEW.book_id;
      IF pub_id IS NOT NULL AND pub_id <> NEW.user_id THEN
        INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
        VALUES (pub_id, 'comment_flagged', 'یک نظر به‌صورت خودکار علامت‌گذاری شد',
          'نظری روی کتاب «' || COALESCE(b_title,'') || '» نیاز به بررسی دارد. دلیل: ' || NEW.flag_reason,
          '/publisher',
          jsonb_build_object('book_id', NEW.book_id, 'comment_id', NEW.id, 'reason', NEW.flag_reason));
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS bc_moderate ON public.book_comments;
CREATE TRIGGER bc_moderate BEFORE INSERT OR UPDATE ON public.book_comments
  FOR EACH ROW EXECUTE FUNCTION public.moderate_book_comment();

-- =========================================================================
-- SMS LOG / SETTINGS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.sms_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  phone text NOT NULL,
  event text NOT NULL,
  body text NOT NULL,
  status text NOT NULL DEFAULT 'sent',
  provider_message_id text,
  error text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sms_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sms_log_select_admin ON public.sms_log;
CREATE POLICY sms_log_select_admin ON public.sms_log FOR SELECT USING (public.is_admin(auth.uid()) OR auth.uid() = user_id);

CREATE TABLE IF NOT EXISTS public.sms_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled boolean NOT NULL DEFAULT false,
  provider text NOT NULL DEFAULT 'kavenegar',
  sender text,
  api_key text,
  api_username text,
  api_password text,
  custom_endpoint text,
  custom_payload_template text,
  tpl_purchase text NOT NULL DEFAULT 'فرابوک: خرید «{title}» با موفقیت انجام شد. {cost} اعتبار کسر شد. مانده: {balance}',
  tpl_credit text NOT NULL DEFAULT 'فرابوک: {amount} اعتبار به حساب شما اضافه شد. مانده: {balance}',
  tpl_revenue text NOT NULL DEFAULT 'فرابوک: {amount} اعتبار درآمد از فروش «{title}» (سهم {role}) به حساب شما اضافه شد.',
  tpl_approval text NOT NULL DEFAULT 'فرابوک: {title} - {body}',
  extra jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sms_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sms_settings_select_admin ON public.sms_settings;
CREATE POLICY sms_settings_select_admin ON public.sms_settings FOR SELECT USING (public.is_admin(auth.uid()));
DROP POLICY IF EXISTS sms_settings_update_admin ON public.sms_settings;
CREATE POLICY sms_settings_update_admin ON public.sms_settings FOR UPDATE USING (public.is_admin(auth.uid()));
INSERT INTO public.sms_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- =========================================================================
-- WORD IMPORTS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.word_imports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  file_path text NOT NULL,
  file_name text NOT NULL,
  file_size bigint NOT NULL DEFAULT 0,
  title text NOT NULL DEFAULT 'کتاب جدید',
  author text NOT NULL DEFAULT 'ناشناس',
  description text,
  status text NOT NULL DEFAULT 'uploaded',
  last_error text,
  book_id uuid,
  chapters_count integer,
  images_count integer,
  skipped_images_count integer,
  attempt_count integer NOT NULL DEFAULT 0,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.word_imports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wi_select_own_or_admin ON public.word_imports;
CREATE POLICY wi_select_own_or_admin ON public.word_imports FOR SELECT USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS wi_insert_own ON public.word_imports;
CREATE POLICY wi_insert_own ON public.word_imports FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS wi_update_own_or_admin ON public.word_imports;
CREATE POLICY wi_update_own_or_admin ON public.word_imports FOR UPDATE USING (auth.uid() = user_id OR public.is_admin(auth.uid()));
DROP POLICY IF EXISTS wi_delete_own_or_admin ON public.word_imports;
CREATE POLICY wi_delete_own_or_admin ON public.word_imports FOR DELETE USING (auth.uid() = user_id OR public.is_admin(auth.uid()));

DROP TRIGGER IF EXISTS wi_touch ON public.word_imports;
CREATE TRIGGER wi_touch BEFORE UPDATE ON public.word_imports
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- =========================================================================
-- HELPER + RPC FUNCTIONS
-- =========================================================================
CREATE OR REPLACE FUNCTION public.compute_fee(_mode text, _value numeric, _base numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE
    WHEN _mode = 'percent' THEN ROUND(_base * _value / 100)
    WHEN _mode = 'fixed' THEN _value
    ELSE 0
  END
$$;

CREATE OR REPLACE FUNCTION public.find_user_by_email(_email text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid;
BEGIN
  IF NOT (public.is_admin(auth.uid()) OR public.is_publisher(auth.uid())) THEN RETURN NULL; END IF;
  SELECT id INTO uid FROM auth.users WHERE lower(email) = lower(_email) LIMIT 1;
  RETURN uid;
END; $$;

CREATE OR REPLACE FUNCTION public.charge_ai_usage(_operation text, _book_id uuid, _model text DEFAULT NULL, _metadata jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid(); fees public.platform_fee_settings%ROWTYPE; cost numeric := 0; usd numeric := 0; balance numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT * INTO fees FROM public.platform_fee_settings WHERE id = 1;
  IF _operation = 'text_suggest' THEN
    cost := COALESCE(fees.ai_text_suggest_cost, 0); usd := COALESCE(fees.ai_text_suggest_usd, 0);
  ELSIF _operation = 'image_gen' THEN
    cost := COALESCE(fees.ai_image_gen_cost, 0); usd := COALESCE(fees.ai_image_gen_usd, 0);
  ELSE RAISE EXCEPTION 'unknown_operation'; END IF;
  SELECT COALESCE(SUM(amount),0) INTO balance FROM public.credit_transactions WHERE user_id = uid;
  IF cost > 0 AND balance < cost THEN RAISE EXCEPTION 'insufficient_credits'; END IF;
  IF cost > 0 THEN
    INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
    VALUES (uid, -cost, 'ai_' || _operation, jsonb_build_object('book_id', _book_id, 'model', _model) || COALESCE(_metadata, '{}'::jsonb));
  END IF;
  INSERT INTO public.ai_usage_log (user_id, book_id, operation, credits_charged, usd_cost, model, metadata)
  VALUES (uid, _book_id, _operation, cost, usd, _model, COALESCE(_metadata, '{}'::jsonb));
  RETURN jsonb_build_object('cost', cost, 'usd', usd, 'new_balance', balance - cost);
END; $$;

CREATE OR REPLACE FUNCTION public.purchase_book(_book_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := auth.uid(); book_price numeric; book_publisher uuid; book_title text;
  cost numeric; balance numeric; already boolean;
  fees public.platform_fee_settings%ROWTYPE; platform_fee numeric := 0; net_amount numeric := 0;
  total_share_percent numeric := 0; share RECORD; share_amount numeric; publisher_remainder numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT price, publisher_id, title INTO book_price, book_publisher, book_title FROM public.books WHERE id = _book_id;
  IF book_price IS NULL THEN RAISE EXCEPTION 'book_not_found'; END IF;
  SELECT EXISTS(SELECT 1 FROM public.user_books WHERE user_id = uid AND book_id = _book_id) INTO already;
  IF already THEN RAISE EXCEPTION 'already_owned'; END IF;
  cost := book_price * 10;
  SELECT COALESCE(SUM(amount),0) INTO balance FROM public.credit_transactions WHERE user_id = uid;
  IF cost > 0 AND balance < cost THEN RAISE EXCEPTION 'insufficient_credits'; END IF;
  IF cost > 0 THEN
    INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
    VALUES (uid, -cost, 'book_purchase', jsonb_build_object('book_id', _book_id));
  END IF;
  INSERT INTO public.user_books (user_id, book_id, acquired_via) VALUES (uid, _book_id, 'purchase');
  SELECT * INTO fees FROM public.platform_fee_settings WHERE id = 1;
  platform_fee := LEAST(cost, public.compute_fee(fees.book_purchase_mode, fees.book_purchase_value, cost));
  net_amount := cost - platform_fee;
  IF net_amount > 0 AND book_publisher IS NOT NULL THEN
    SELECT COALESCE(SUM(percent),0) INTO total_share_percent FROM public.book_revenue_shares WHERE book_id = _book_id AND role IN ('author','editor');
    FOR share IN SELECT user_id, role, percent FROM public.book_revenue_shares WHERE book_id = _book_id AND role IN ('author','editor') AND percent > 0 LOOP
      share_amount := ROUND(net_amount * share.percent / 100);
      IF share_amount > 0 THEN
        INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
        VALUES (share.user_id, share_amount, 'revenue_share_' || share.role,
                jsonb_build_object('book_id', _book_id, 'buyer_id', uid, 'percent', share.percent));
        INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
        VALUES (share.user_id, 'revenue_received', 'درآمد جدید از فروش کتاب',
                'مبلغ ' || share_amount::text || ' اعتبار بابت سهم ' || share.role || ' از فروش «' || book_title || '» به حساب شما اضافه شد.',
                '/profile?tab=earnings',
                jsonb_build_object('book_id', _book_id, 'amount', share_amount, 'role', share.role));
      END IF;
    END LOOP;
    publisher_remainder := net_amount - ROUND(net_amount * total_share_percent / 100);
    IF publisher_remainder > 0 THEN
      INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
      VALUES (book_publisher, publisher_remainder, 'revenue_share_publisher',
              jsonb_build_object('book_id', _book_id, 'buyer_id', uid));
      INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
      VALUES (book_publisher, 'revenue_received', 'درآمد جدید از فروش کتاب',
              'مبلغ ' || publisher_remainder::text || ' اعتبار بابت سهم ناشر از فروش «' || book_title || '» به حساب شما اضافه شد.',
              '/profile?tab=earnings',
              jsonb_build_object('book_id', _book_id, 'amount', publisher_remainder, 'role', 'publisher'));
    END IF;
  END IF;
  INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
  VALUES (uid, 'purchase_success', 'خرید موفق',
          'کتاب «' || book_title || '» به قفسه شما اضافه شد. ' || cost::text || ' اعتبار کسر شد.',
          '/library', jsonb_build_object('book_id', _book_id, 'cost', cost));
  RETURN jsonb_build_object('cost', cost, 'previous_balance', balance, 'new_balance', balance - cost,
                            'platform_fee', platform_fee, 'net_distributed', net_amount, 'price', book_price);
END; $$;

CREATE OR REPLACE FUNCTION public.publish_book_paid(_book_id uuid, _complexity integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid(); book RECORD; fees public.platform_fee_settings%ROWTYPE; factor int; fee numeric; balance numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT * INTO book FROM public.books WHERE id = _book_id;
  IF book IS NULL THEN RAISE EXCEPTION 'book_not_found'; END IF;
  IF book.publisher_id <> uid AND NOT public.is_admin(uid) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  IF book.first_published_paid THEN RETURN jsonb_build_object('skipped', true, 'reason', 'already_paid'); END IF;
  factor := GREATEST(1, LEAST(10, COALESCE(_complexity, 1)));
  SELECT * INTO fees FROM public.platform_fee_settings WHERE id = 1;
  IF fees.book_publish_mode = 'percent' THEN fee := ROUND(book.price * 10 * fees.book_publish_value / 100) * factor;
  ELSE fee := fees.book_publish_value * factor; END IF;
  SELECT COALESCE(SUM(amount),0) INTO balance FROM public.credit_transactions WHERE user_id = uid;
  IF fee > 0 AND balance < fee THEN RAISE EXCEPTION 'insufficient_credits'; END IF;
  IF fee > 0 THEN
    INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
    VALUES (uid, -fee, 'book_publish_fee', jsonb_build_object('book_id', _book_id, 'complexity', factor));
  END IF;
  UPDATE public.books SET first_published_paid = true, publish_complexity_factor = factor WHERE id = _book_id;
  INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
  VALUES (uid, 'fee_charged', 'هزینه انتشار کسر شد',
          'بابت انتشار کتاب «' || book.title || '» مبلغ ' || fee::text || ' اعتبار کسر شد.',
          '/publisher', jsonb_build_object('book_id', _book_id, 'fee', fee, 'complexity', factor));
  RETURN jsonb_build_object('fee', fee, 'complexity', factor, 'new_balance', balance - fee);
END; $$;

CREATE OR REPLACE FUNCTION public.request_publisher_upgrade_paid(_display_name text, _bio text DEFAULT NULL, _website text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid(); fees public.platform_fee_settings%ROWTYPE; fee numeric; balance numeric; req_id uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF public.is_publisher(uid) THEN RAISE EXCEPTION 'already_publisher'; END IF;
  SELECT * INTO fees FROM public.platform_fee_settings WHERE id = 1;
  fee := COALESCE(fees.publisher_signup_value, 0);
  SELECT COALESCE(SUM(amount),0) INTO balance FROM public.credit_transactions WHERE user_id = uid;
  IF fee > 0 AND balance < fee THEN RAISE EXCEPTION 'insufficient_credits'; END IF;
  IF fee > 0 THEN
    INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
    VALUES (uid, -fee, 'publisher_signup_fee', jsonb_build_object('display_name', _display_name));
  END IF;
  INSERT INTO public.publisher_upgrade_requests (user_id, display_name, bio, website, credits_offered)
  VALUES (uid, _display_name, _bio, _website, fee) RETURNING id INTO req_id;
  INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
  VALUES (uid, 'fee_charged', 'هزینه ناشر شدن کسر شد',
          'مبلغ ' || fee::text || ' اعتبار بابت درخواست ناشر شدن کسر شد. درخواست شما در حال بررسی است.',
          '/profile?tab=earnings', jsonb_build_object('request_id', req_id, 'fee', fee));
  RETURN jsonb_build_object('request_id', req_id, 'fee', fee, 'new_balance', balance - fee);
END; $$;

CREATE OR REPLACE FUNCTION public.set_book_revenue_shares(_book_id uuid, _shares jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid := auth.uid(); share jsonb; total numeric := 0; fees public.platform_fee_settings%ROWTYPE; reserved_pct numeric;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT (EXISTS(SELECT 1 FROM public.books WHERE id = _book_id AND publisher_id = uid) OR public.is_admin(uid)) THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;
  SELECT * INTO fees FROM public.platform_fee_settings WHERE id = 1;
  reserved_pct := CASE WHEN fees.book_purchase_mode = 'percent' THEN fees.book_purchase_value ELSE 0 END;
  FOR share IN SELECT * FROM jsonb_array_elements(_shares) LOOP
    total := total + (share->>'percent')::numeric;
  END LOOP;
  IF total + reserved_pct > 100 THEN RAISE EXCEPTION 'shares_exceed_100'; END IF;
  DELETE FROM public.book_revenue_shares WHERE book_id = _book_id;
  FOR share IN SELECT * FROM jsonb_array_elements(_shares) LOOP
    IF (share->>'user_id') IS NOT NULL AND (share->>'percent')::numeric > 0 THEN
      INSERT INTO public.book_revenue_shares (book_id, user_id, role, percent)
      VALUES (_book_id, (share->>'user_id')::uuid, share->>'role', (share->>'percent')::numeric)
      ON CONFLICT (book_id, user_id, role) DO UPDATE SET percent = EXCLUDED.percent;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('total_assigned', total, 'platform_reserved', reserved_pct);
END; $$;

CREATE OR REPLACE FUNCTION public.accept_editor_request(_request_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE req public.editor_access_requests%ROWTYPE; caller_email text;
BEGIN
  SELECT * INTO req FROM public.editor_access_requests WHERE id = _request_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'request_not_found'; END IF;
  IF req.status <> 'pending' THEN RAISE EXCEPTION 'request_not_pending'; END IF;
  SELECT email INTO caller_email FROM auth.users WHERE id = auth.uid();
  IF NOT (auth.uid() = req.editor_user_id
          OR (req.editor_user_id IS NULL AND lower(caller_email) = lower(req.editor_email))
          OR public.is_admin(auth.uid())) THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;
  INSERT INTO public.user_roles (user_id, role, granted_by)
  VALUES (auth.uid(), 'editor', req.publisher_id) ON CONFLICT (user_id, role) DO NOTHING;
  INSERT INTO public.book_editors (book_id, editor_id, granted_by, can_publish)
  VALUES (req.book_id, auth.uid(), req.publisher_id, req.can_publish) ON CONFLICT DO NOTHING;
  UPDATE public.editor_access_requests
     SET status = 'accepted', reviewed_at = now(), reviewed_by = auth.uid(), editor_user_id = auth.uid()
   WHERE id = _request_id;
  RETURN req.book_id;
END; $$;

CREATE OR REPLACE FUNCTION public.complete_payment_order(_order_id uuid, _ref_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ord public.payment_orders%ROWTYPE; new_balance numeric;
BEGIN
  SELECT * INTO ord FROM public.payment_orders WHERE id = _order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;
  IF ord.status = 'paid' THEN
    SELECT COALESCE(SUM(amount),0) INTO new_balance FROM public.credit_transactions WHERE user_id = ord.user_id;
    RETURN jsonb_build_object('already_paid', true, 'credits', ord.credits, 'new_balance', new_balance);
  END IF;
  UPDATE public.payment_orders SET status = 'paid', ref_id = _ref_id, updated_at = now() WHERE id = _order_id;
  INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
  VALUES (ord.user_id, ord.credits, 'bank_topup',
          jsonb_build_object('order_id', ord.id, 'gateway', ord.gateway, 'amount_toman', ord.amount_toman, 'ref_id', _ref_id, 'authority', ord.authority));
  SELECT COALESCE(SUM(amount),0) INTO new_balance FROM public.credit_transactions WHERE user_id = ord.user_id;
  INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
  VALUES (ord.user_id, 'credit_topup', 'افزایش اعتبار از درگاه بانکی',
          'مبلغ ' || ord.amount_toman::text || ' تومان واریز شد و ' || ord.credits::text || ' اعتبار به حساب شما اضافه شد.',
          '/credits', jsonb_build_object('order_id', ord.id, 'ref_id', _ref_id));
  RETURN jsonb_build_object('credits', ord.credits, 'new_balance', new_balance, 'ref_id', _ref_id);
END; $$;

CREATE OR REPLACE FUNCTION public.fail_payment_order(_order_id uuid, _reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.payment_orders
    SET status = CASE WHEN status = 'paid' THEN status ELSE 'failed' END,
        metadata = metadata || jsonb_build_object('fail_reason', _reason),
        updated_at = now()
  WHERE id = _order_id;
END; $$;

CREATE OR REPLACE FUNCTION public.update_book_pages_partial(_book_id uuid, _patches jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE patch jsonb; cur jsonb; idx int; page jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT public.can_edit_book(auth.uid(), _book_id) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT pages INTO cur FROM public.books WHERE id = _book_id FOR UPDATE;
  IF cur IS NULL THEN cur := '[]'::jsonb; END IF;
  FOR patch IN SELECT * FROM jsonb_array_elements(_patches) LOOP
    idx := (patch->>'index')::int; page := patch->'page';
    IF page IS NULL THEN CONTINUE; END IF;
    WHILE jsonb_array_length(cur) <= idx LOOP
      cur := cur || jsonb_build_array(jsonb_build_object('title','—','blocks','[]'::jsonb));
    END LOOP;
    cur := jsonb_set(cur, array[idx::text], page, true);
  END LOOP;
  UPDATE public.books SET pages = cur, updated_at = now() WHERE id = _book_id;
END; $$;

-- =========================================================================
-- ADMIN RPCs
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_list_users()
RETURNS TABLE(id uuid, email text, display_name text, username text, national_id text, is_active boolean, credits numeric, created_at timestamptz, roles text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  RETURN QUERY
  SELECT p.id, u.email::text, p.display_name, p.username, p.national_id, p.is_active,
         COALESCE(ct.total, 0), p.created_at, COALESCE(r.roles, ARRAY[]::text[])
  FROM public.profiles p
  LEFT JOIN auth.users u ON u.id = p.id
  LEFT JOIN LATERAL (SELECT SUM(amount) AS total FROM public.credit_transactions WHERE user_id = p.id) ct ON true
  LEFT JOIN LATERAL (SELECT array_agg(role::text ORDER BY role::text) AS roles FROM public.user_roles WHERE user_id = p.id) r ON true
  ORDER BY p.created_at DESC;
END; $$;

CREATE OR REPLACE FUNCTION public.admin_adjust_credits(_user_id uuid, _amount numeric, _reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  INSERT INTO public.credit_transactions (user_id, amount, reason, created_by)
  VALUES (_user_id, _amount, COALESCE(_reason, 'admin_adjust'), auth.uid());
END; $$;

CREATE OR REPLACE FUNCTION public.admin_set_role(_user_id uuid, _role public.app_role, _grant boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_super_admin(auth.uid()) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  IF _grant THEN
    INSERT INTO public.user_roles (user_id, role, granted_by) VALUES (_user_id, _role, auth.uid())
    ON CONFLICT (user_id, role) DO NOTHING;
  ELSE
    DELETE FROM public.user_roles WHERE user_id = _user_id AND role = _role;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.admin_purge_user(_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_super_admin(auth.uid()) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  DELETE FROM public.book_comments WHERE user_id = _user_id;
  DELETE FROM public.highlights WHERE user_id = _user_id;
  DELETE FROM public.user_books WHERE user_id = _user_id;
  DELETE FROM public.book_editors WHERE editor_id = _user_id;
  DELETE FROM public.editor_access_requests WHERE publisher_id = _user_id OR editor_user_id = _user_id;
  DELETE FROM public.credit_transactions WHERE user_id = _user_id;
  DELETE FROM public.credit_purchase_requests WHERE user_id = _user_id;
  DELETE FROM public.publisher_upgrade_requests WHERE user_id = _user_id;
  DELETE FROM public.publisher_profiles WHERE user_id = _user_id;
  DELETE FROM public.user_roles WHERE user_id = _user_id;
  DELETE FROM public.profiles WHERE id = _user_id;
END; $$;

CREATE OR REPLACE FUNCTION public.admin_update_platform_fees(_settings jsonb)
RETURNS public.platform_fee_settings LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE result public.platform_fee_settings;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  UPDATE public.platform_fee_settings SET
    book_purchase_mode = COALESCE(_settings->>'book_purchase_mode', book_purchase_mode),
    book_purchase_value = COALESCE((_settings->>'book_purchase_value')::numeric, book_purchase_value),
    editor_order_mode = COALESCE(_settings->>'editor_order_mode', editor_order_mode),
    editor_order_value = COALESCE((_settings->>'editor_order_value')::numeric, editor_order_value),
    publisher_signup_mode = COALESCE(_settings->>'publisher_signup_mode', publisher_signup_mode),
    publisher_signup_value = COALESCE((_settings->>'publisher_signup_value')::numeric, publisher_signup_value),
    book_publish_mode = COALESCE(_settings->>'book_publish_mode', book_publish_mode),
    book_publish_value = COALESCE((_settings->>'book_publish_value')::numeric, book_publish_value),
    ai_text_suggest_cost = COALESCE((_settings->>'ai_text_suggest_cost')::numeric, ai_text_suggest_cost),
    ai_image_gen_cost = COALESCE((_settings->>'ai_image_gen_cost')::numeric, ai_image_gen_cost),
    ai_text_suggest_usd = COALESCE((_settings->>'ai_text_suggest_usd')::numeric, ai_text_suggest_usd),
    ai_image_gen_usd = COALESCE((_settings->>'ai_image_gen_usd')::numeric, ai_image_gen_usd),
    credits_per_toman = COALESCE((_settings->>'credits_per_toman')::numeric, credits_per_toman),
    updated_at = now(), updated_by = auth.uid()
  WHERE id = 1 RETURNING * INTO result;
  RETURN result;
END; $$;

CREATE OR REPLACE FUNCTION public.admin_recent_ai_usage(_limit integer DEFAULT 200)
RETURNS TABLE(id uuid, created_at timestamptz, user_id uuid, user_name text, book_id uuid, book_title text, operation text, credits_charged numeric, usd_cost numeric, model text, metadata jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  RETURN QUERY
  SELECT a.id, a.created_at, a.user_id,
         COALESCE(p.display_name, p.username, substring(a.user_id::text, 1, 8)),
         a.book_id, b.title, a.operation, a.credits_charged, a.usd_cost, a.model, a.metadata
  FROM public.ai_usage_log a
  LEFT JOIN public.profiles p ON p.id = a.user_id
  LEFT JOIN public.books b ON b.id = a.book_id
  ORDER BY a.created_at DESC
  LIMIT GREATEST(1, LEAST(1000, _limit));
END; $$;

CREATE OR REPLACE FUNCTION public.admin_recent_transactions(_limit integer DEFAULT 100)
RETURNS TABLE(id uuid, created_at timestamptz, reason text, amount numeric, user_id uuid, user_name text, user_email text, book_id uuid, book_title text, buyer_id uuid, buyer_name text, metadata jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  RETURN QUERY
  SELECT t.id, t.created_at, t.reason, t.amount, t.user_id,
         COALESCE(p.display_name, p.username, substring(t.user_id::text, 1, 8)),
         u.email::text,
         NULLIF(t.metadata->>'book_id','')::uuid, b.title,
         NULLIF(t.metadata->>'buyer_id','')::uuid,
         COALESCE(bp.display_name, bp.username),
         t.metadata
  FROM public.credit_transactions t
  LEFT JOIN public.profiles p ON p.id = t.user_id
  LEFT JOIN auth.users u ON u.id = t.user_id
  LEFT JOIN public.books b ON b.id = NULLIF(t.metadata->>'book_id','')::uuid
  LEFT JOIN public.profiles bp ON bp.id = NULLIF(t.metadata->>'buyer_id','')::uuid
  ORDER BY t.created_at DESC
  LIMIT GREATEST(1, LEAST(500, _limit));
END; $$;

CREATE OR REPLACE FUNCTION public.publisher_book_sales_stats(_publisher_id uuid)
RETURNS TABLE(book_id uuid, sales_count integer, gross_credits numeric, to_publisher numeric, distribution jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (auth.uid() = _publisher_id OR public.is_admin(auth.uid())) THEN RAISE EXCEPTION 'not_authorized'; END IF;
  RETURN QUERY
  WITH my_books AS (SELECT id FROM public.books WHERE publisher_id = _publisher_id),
  purchases AS (
    SELECT (t.metadata->>'book_id')::uuid AS book_id, ABS(t.amount) AS amount
    FROM public.credit_transactions t
    WHERE t.reason = 'book_purchase' AND t.amount < 0
      AND (t.metadata->>'book_id')::uuid IN (SELECT id FROM my_books)
  ),
  shares AS (
    SELECT (t.metadata->>'book_id')::uuid AS book_id, t.user_id AS recipient_id,
           replace(t.reason, 'revenue_share_', '') AS role, t.amount AS amount,
           COALESCE(p.display_name, p.username, substring(t.user_id::text, 1, 8)) AS recipient_name
    FROM public.credit_transactions t
    LEFT JOIN public.profiles p ON p.id = t.user_id
    WHERE t.reason LIKE 'revenue_share_%' AND t.amount > 0
      AND (t.metadata->>'book_id')::uuid IN (SELECT id FROM my_books)
  )
  SELECT b.id,
    COALESCE((SELECT COUNT(*)::int FROM purchases p WHERE p.book_id = b.id), 0),
    COALESCE((SELECT SUM(amount) FROM purchases p WHERE p.book_id = b.id), 0),
    COALESCE((SELECT SUM(amount) FROM shares s WHERE s.book_id = b.id AND s.recipient_id = _publisher_id), 0),
    COALESCE((SELECT jsonb_agg(jsonb_build_object('recipient_id', s.recipient_id, 'recipient_name', s.recipient_name, 'role', s.role, 'amount', s.amount))
              FROM shares s WHERE s.book_id = b.id), '[]'::jsonb)
  FROM my_books b;
END; $$;

-- =========================================================================
-- STORAGE BUCKETS + POLICIES
-- =========================================================================
INSERT INTO storage.buckets (id, name) VALUES ('book-uploads', 'book-uploads')
  ON CONFLICT (id) DO NOTHING;
INSERT INTO storage.buckets (id, name) VALUES ('book-media', 'book-media')
  ON CONFLICT (id) DO NOTHING;

-- book-uploads: per-user folder (uid as first path segment)
DROP POLICY IF EXISTS "book-uploads read own" ON storage.objects;
CREATE POLICY "book-uploads read own" ON storage.objects FOR SELECT
  USING (bucket_id = 'book-uploads' AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid())));
DROP POLICY IF EXISTS "book-uploads insert own" ON storage.objects;
CREATE POLICY "book-uploads insert own" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'book-uploads' AND auth.uid()::text = (storage.foldername(name))[1]);
DROP POLICY IF EXISTS "book-uploads update own" ON storage.objects;
CREATE POLICY "book-uploads update own" ON storage.objects FOR UPDATE
  USING (bucket_id = 'book-uploads' AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid())));
DROP POLICY IF EXISTS "book-uploads delete own" ON storage.objects;
CREATE POLICY "book-uploads delete own" ON storage.objects FOR DELETE
  USING (bucket_id = 'book-uploads' AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin(auth.uid())));

-- book-media: public read; authenticated write
DROP POLICY IF EXISTS "book-media public read" ON storage.objects;
CREATE POLICY "book-media public read" ON storage.objects FOR SELECT USING (bucket_id = 'book-media');
DROP POLICY IF EXISTS "book-media auth insert" ON storage.objects;
CREATE POLICY "book-media auth insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'book-media' AND auth.uid() IS NOT NULL);
DROP POLICY IF EXISTS "book-media auth update own" ON storage.objects;
CREATE POLICY "book-media auth update own" ON storage.objects FOR UPDATE
  USING (bucket_id = 'book-media' AND (auth.uid() = owner OR public.is_admin(auth.uid())));
DROP POLICY IF EXISTS "book-media auth delete own" ON storage.objects;
CREATE POLICY "book-media auth delete own" ON storage.objects FOR DELETE
  USING (bucket_id = 'book-media' AND (auth.uid() = owner OR public.is_admin(auth.uid())));