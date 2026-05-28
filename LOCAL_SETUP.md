# راهنمای راه‌اندازی لوکال (آفلاین)

این پروژه اکنون می‌تواند کاملاً روی سیستم لوکال شما بدون نیاز به اینترنت اجرا شود.

## پیش‌نیازها

1. **Docker Desktop** — نصب و اجرا شود
2. **Supabase CLI** — نصب شود:
   ```bash
   npm install -g supabase
   ```

### سازگاری نسخه‌های شما

نسخه‌های زیر با هم ناسازگاری مستقیم ندارند:
- Docker Desktop `4.75.0` / Docker Engine `29.5.2`
- Supabase CLI `2.101.0`

خطای `supabase_analytics` یا `supabase_vector ... unhealthy` معمولاً از سرویس لاگ/آنالیتیکس لوکال می‌آید، نه از خود دیتابیس یا برنامه. در این پروژه آن سرویس در `supabase/config.toml` غیرفعال شده است تا روی Windows Server + WSL2 مانع بالا آمدن محیط لوکال نشود.

## مراحل راه‌اندازی

### ۱. کلون پروژه
```bash
cd /path/to/project
```

### ۲. راه‌اندازی Supabase لوکال
اگر قبلاً خطای container unhealthy گرفته‌اید، ابتدا کانتینرها و volumeهای قبلی همین پروژه را پاک کنید:

```bash
supabase stop --no-backup
```

سپس دوباره اجرا کنید:

```bash
supabase start
```
این دستور:
- Postgres لوکال را روی پورت `54322` بالا می‌آورد
- API را روی `54321` فعال می‌کند
- Studio (داشبورد) را روی `54323` اجرا می‌کند

اگر پروژه داخل مسیر `/mnt/c/...` است و Docker خطای mount یا unhealthy داد، بهتر است پروژه را داخل فایل‌سیستم Ubuntu کپی کنید؛ مثلاً:

```bash
cp -r /mnt/c/Users/Administrator/Documents/GitHub/test-config-copyfarabook ~/test-config-copyfarabook
cd ~/test-config-copyfarabook
supabase stop --no-backup
supabase start
```

در Docker Desktop هم مطمئن شوید WSL Integration برای توزیع Ubuntu فعال است.

### ۲.۱ اتصال فرانت‌اند به Supabase لوکال
فایل `.env` پروژه برای نسخه آنلاین تنظیم شده است. برای اجرای کاملاً لوکال، یک فایل `.env.local` بسازید تا Vite از بک‌اند لوکال استفاده کند:

```bash
cp .env.local.example .env.local
```

بعد از اجرای موفق `supabase start`، مقدار `ANON_KEY` را از خروجی دستور زیر بردارید و در `.env.local` جلوی `VITE_SUPABASE_PUBLISHABLE_KEY` قرار دهید:

```bash
supabase status
```

### ۳. اجرای Migrationها
Migrationها به طور خودکار با `supabase start` اجرا می‌شوند. اگر نیاز به ریست داشتید:
```bash
supabase db reset
```

### ۴. وارد کردن داده‌های نمونه (Seed)
```bash
psql postgresql://postgres:postgres@localhost:54322/postgres -f supabase/seed.sql
```
یا از طریق Studio:
- به `http://localhost:54323` بروید
- SQL Editor را باز کنید
- محتوای `supabase/seed.sql` را paste و Run کنید

### ۵. اجرای فرانت‌اند
```bash
npm install
npm run dev
```

اگر از داخل WSL اجرا می‌کنید و می‌خواهید از ویندوز هم باز شود:

```bash
npm run dev -- --host 0.0.0.0
```

## اکانت‌های تست

| ایمیل | رمز عبور | نقش |
|-------|----------|-----|
| `user1@test.com` | `Test1234!` | کاربر |
| `user2@test.com` | `Test1234!` | کاربر |
| `publisher1@test.com` | `Test1234!` | ناشر |
| `editor1@test.com` | `Test1234!` | ویرایشگر |

## مشخصات داده‌ها

- **۳۱ کتاب** در ۹ دسته (علمی، فرهنگی، ورزشی، ریاضی، درسی، پزشکی، داستان، کودک، تست)
- **کتاب ۱۰۰ صفحه‌ای** با ویدیو و نقاط تعاملی برای تست عملکرد
- **کتاب کودک** با تصاویر تعاملی و اسلایدشو
- **۵۰۰ اعتبار** برای هر اکانت تست

## دسترسی به سرویس‌های لوکال

| سرویس | آدرس |
|-------|------|
| Studio | http://localhost:54323 |
| API | http://localhost:54321 |
| Postgres | postgresql://postgres:postgres@localhost:54322/postgres |
| Inbucket (ایمیل) | http://localhost:54324 |

## توقف و پاک کردن

```bash
supabase stop          # توقف
supabase stop --reset  # توقف و حذف داده‌ها
```

## نکات مهم

- نیازی به اینترنت نیست (بعد از `supabase start`)
- تصاویر کتاب‌ها از URLs آنلاین بارگذاری می‌شوند؛ برای کاملاً آفلاین، تصاویر را در `public/images` کپی کنید و URLs را در seed.sql تغییر دهید
- Edge Functions هوش مصنوعی (AI) نیاز به API Key و اینترنت دارند
