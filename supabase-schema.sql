-- ============================================================
-- KOC 兑换系统 · Supabase Schema
-- 在 Supabase SQL Editor 中执行一次
-- 设计原则：现在全手动，以后自动算分无缝接入
-- ============================================================

-- 1. KOC 表（手动维护，以后主系统可接管）
CREATE TABLE kocs (
  uid TEXT PRIMARY KEY,              -- "YOYO-001" 格式
  discord_name TEXT NOT NULL,         -- Discord 昵称，KOC 登录时验证
  name TEXT DEFAULT '',               -- Full Legal Name / 真实姓名
  channel_tag TEXT DEFAULT '',        -- TT/Ins/FB/Reddit
  status TEXT DEFAULT 'active' CHECK(status IN ('active','inactive')),
  region TEXT DEFAULT '',             -- 地区
  address TEXT DEFAULT '',            -- 收货地址
  account_id TEXT DEFAULT '',         -- 游戏 Account ID
  server TEXT DEFAULT '',             -- 正式服/灯塔服
  notes TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. 积分流水表（唯一积分真相源）
--    source=manual      → 你现在手动录入
--    source=auto_settlement → 以后主系统自动写入
--    source=redemption   → KOC 兑换扣除（系统自动）
CREATE TABLE point_logs (
  id BIGSERIAL PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES kocs(uid),
  change INTEGER NOT NULL,           -- 正数加分，负数扣分
  balance_after INTEGER NOT NULL,    -- 变动后余额
  source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual','auto_settlement','redemption')),
  reason TEXT NOT NULL,              -- "6月投稿结算" / "兑换钻石"
  period TEXT DEFAULT '',            -- "2026-06" 自动结算月份
  created_by TEXT DEFAULT '',        -- 操作人
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. 兑换订单表
CREATE TABLE redemption_orders (
  id BIGSERIAL PRIMARY KEY,
  uid TEXT NOT NULL REFERENCES kocs(uid),
  discord_name TEXT NOT NULL,         -- 下单时 KOC 输入的 Discord 名
  koc_name TEXT DEFAULT '',
  option_type TEXT NOT NULL CHECK(option_type IN ('diamonds','gplay','merch')),
  option_name TEXT DEFAULT '',
  points_spent INTEGER NOT NULL,
  reward_amount TEXT DEFAULT '',
  contact_info TEXT DEFAULT '',       -- JSON 收货信息
  status TEXT DEFAULT 'pending' CHECK(status IN ('pending','processing','shipped','cancelled')),
  admin_notes TEXT DEFAULT '',
  period TEXT DEFAULT '',
  request_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  processed_by TEXT DEFAULT ''
);

-- 4. 兑换选项表（后台可配）
CREATE TABLE reward_options (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  points_cost INTEGER NOT NULL,
  description TEXT DEFAULT '',
  amount_text TEXT DEFAULT '',
  is_active BOOLEAN DEFAULT true
);

-- 初始兑换选项
INSERT INTO reward_options (name, points_cost, description, amount_text) VALUES
  ('💎 钻石', 1, '1 积分 = 450 钻石', '450 钻石'),
  ('🎮 Google Play $10', 2, '2 积分 = $10 礼品卡', '$10 Google Play 礼品卡'),
  ('📦 周边福袋', 5, '5 积分 = 随机 3 件周边', '随机周边 × 3');

-- 索引
CREATE INDEX idx_point_logs_uid ON point_logs(uid);
CREATE INDEX idx_point_logs_created ON point_logs(created_at DESC);
CREATE INDEX idx_redemption_orders_uid ON redemption_orders(uid);
CREATE INDEX idx_redemption_orders_status ON redemption_orders(status);
CREATE INDEX idx_redemption_orders_created ON redemption_orders(created_at DESC);
CREATE UNIQUE INDEX idx_redemption_orders_uid_request_type_unique
  ON redemption_orders(uid, request_id, option_type)
  WHERE request_id IS NOT NULL AND request_id <> '';

-- 当前积分视图
DROP VIEW IF EXISTS koc_balances;
CREATE VIEW koc_balances AS
SELECT
  k.uid, k.discord_name, k.name AS full_legal_name, k.channel_tag, k.status,
  COALESCE((SELECT SUM(pl.change) FROM point_logs pl WHERE pl.uid = k.uid), 0)::INTEGER AS current_points
FROM kocs k
WHERE k.status = 'active';

-- 获取当前积分（按流水汇总，避免依赖最后一条 balance_after）
CREATE OR REPLACE FUNCTION get_balance(p_uid TEXT)
RETURNS INTEGER AS $$
  SELECT COALESCE(SUM(change), 0)::INTEGER
  FROM point_logs
  WHERE uid = p_uid;
$$ LANGUAGE SQL STABLE;

-- 原子兑换：一次性校验余额并写入多条兑换订单
CREATE OR REPLACE FUNCTION redeem_points(
  p_uid TEXT,
  p_period TEXT,
  p_items JSONB,
  p_contact_info TEXT DEFAULT '',
  p_request_id TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_available INTEGER;
  v_pending INTEGER;
  v_total_cost INTEGER := 0;
  v_item JSONB;
  v_order_count INTEGER := 0;
  v_existing_count INTEGER := 0;
  v_existing_cost INTEGER := 0;
BEGIN
  IF p_uid IS NULL OR btrim(p_uid) = '' THEN
    RAISE EXCEPTION 'p_uid is required';
  END IF;
  IF p_period IS NULL OR btrim(p_period) = '' THEN
    RAISE EXCEPTION 'p_period is required';
  END IF;
  IF p_request_id IS NULL OR btrim(p_request_id) = '' THEN
    p_request_id := gen_random_uuid()::TEXT;
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_uid));

  SELECT COUNT(*), COALESCE(SUM(points_spent), 0)::INTEGER
  INTO v_existing_count, v_existing_cost
  FROM redemption_orders
  WHERE uid = p_uid AND request_id = p_request_id;

  IF v_existing_count > 0 THEN
    SELECT COALESCE(SUM(change), 0)::INTEGER INTO v_available
    FROM point_logs
    WHERE uid = p_uid;

    SELECT COALESCE(SUM(points_spent), 0)::INTEGER INTO v_pending
    FROM redemption_orders
    WHERE uid = p_uid AND status = 'pending';

    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'order_count', v_existing_count,
      'available_before', v_available - v_pending + v_existing_cost,
      'total_cost', v_existing_cost,
      'available_after', v_available - v_pending
    );
  END IF;

  SELECT COALESCE(SUM(change), 0)::INTEGER INTO v_available
  FROM point_logs
  WHERE uid = p_uid;

  SELECT COALESCE(SUM(points_spent), 0)::INTEGER INTO v_pending
  FROM redemption_orders
  WHERE uid = p_uid AND status = 'pending';

  v_available := v_available - v_pending;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF COALESCE(NULLIF(v_item->>'option_type', ''), '') = '' THEN
      RAISE EXCEPTION 'option_type is required';
    END IF;
    IF COALESCE(NULLIF(v_item->>'option_name', ''), '') = '' THEN
      RAISE EXCEPTION 'option_name is required';
    END IF;
    IF COALESCE((v_item->>'points_spent')::INTEGER, 0) <= 0 THEN
      RAISE EXCEPTION 'points_spent must be positive';
    END IF;
    v_total_cost := v_total_cost + COALESCE((v_item->>'points_spent')::INTEGER, 0);
  END LOOP;

  IF v_total_cost > v_available THEN
    RAISE EXCEPTION 'insufficient points: available %, required %', v_available, v_total_cost;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO redemption_orders (
      uid, discord_name, koc_name,
      option_type, option_name, points_spent, reward_amount,
      contact_info, status, period, request_id, created_at
    ) VALUES (
      p_uid,
      COALESCE(v_item->>'discord_name', ''),
      COALESCE(v_item->>'koc_name', ''),
      COALESCE(v_item->>'option_type', ''),
      COALESCE(v_item->>'option_name', ''),
      COALESCE((v_item->>'points_spent')::INTEGER, 0),
      COALESCE(v_item->>'reward_amount', ''),
      COALESCE(NULLIF(v_item->>'contact_info', ''), p_contact_info),
      'pending',
      p_period,
      p_request_id,
      NOW()
    );
    v_order_count := v_order_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'idempotent', false,
    'order_count', v_order_count,
    'available_before', v_available,
    'total_cost', v_total_cost,
    'available_after', v_available - v_total_cost
  );
END;
$$;

GRANT EXECUTE ON FUNCTION redeem_points(TEXT, TEXT, JSONB, TEXT, TEXT) TO anon, authenticated;


-- 约定式 UID helper：生成下一个可用 KOC UID
CREATE OR REPLACE FUNCTION next_koc_uid()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_next INTEGER;
BEGIN
  PERFORM pg_advisory_xact_lock(424242);
  SELECT COALESCE(MAX(CASE WHEN uid ~ '^YOYO-[0-9]+$' THEN substring(uid FROM 6)::INTEGER END), 0) + 1
    INTO v_next
  FROM kocs;
  RETURN 'YOYO-' || LPAD(v_next::TEXT, 3, '0');
END;
$$;
-- ============================================================
-- 新增：作品提交表（创作者端投稿 / 管理员审核）
-- 2026-07 月结活动
-- ============================================================

-- 5. 作品提交表
CREATE TABLE submissions (
  id BIGSERIAL PRIMARY KEY,
  discord_name TEXT NOT NULL,           -- 投稿人 Discord 用户名
  uid TEXT NOT NULL REFERENCES kocs(uid), -- KOC UID
  server TEXT NOT NULL DEFAULT '',       -- Beacon Server / Official Server
  address TEXT DEFAULT '',               -- 收货地址（可选）
  account_id TEXT DEFAULT '',            -- Account ID（可选）
  game_uid TEXT DEFAULT '',              -- Game UID（可选）
  feedback TEXT DEFAULT '',              -- 反馈意见（可选）
  links_engagement TEXT NOT NULL DEFAULT '',     -- 互动平台链接（Pinterest/FB/IG/X/Reddit），逗号分隔
  links_views TEXT NOT NULL DEFAULT '',          -- 播放平台链接（TikTok/YouTube），逗号分隔
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','scored','rejected')),
  -- 算分结果（由 Agent 填写 / 导入时填充）
  score_details TEXT DEFAULT '',          -- JSON: 每条链接的互动数/播放量详情
  total_engagement_count INTEGER DEFAULT 0,  -- 总互动量
  total_view_count INTEGER DEFAULT 0,        -- 总播放量
  points_earned INTEGER DEFAULT 0,           -- 本次投稿获得积分
  scored_at TIMESTAMPTZ,                     -- 算分时间
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_submissions_status ON submissions(status);
CREATE INDEX idx_submissions_uid ON submissions(uid);
CREATE INDEX idx_submissions_created ON submissions(created_at DESC);

-- ============================================================
-- 新增：积分导入记录表（追踪 Agent 算分导入历史）
-- ============================================================
CREATE TABLE score_imports (
  id BIGSERIAL PRIMARY KEY,
  batch_id TEXT NOT NULL,               -- 批次标识（如 "2026-07"）
  total_submissions INTEGER NOT NULL DEFAULT 0,
  total_points_added INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'agent', -- agent / manual
  import_data TEXT,                     -- 导入的原始 JSON 数据（审计用）
  imported_by TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_score_imports_batch ON score_imports(batch_id);

-- 更新 koc_balances 视图（submissions 表的积分也计入）
-- DROP VIEW IF EXISTS koc_balances;
-- CREATE VIEW koc_balances AS
-- SELECT 
--   k.uid, k.discord_name, k.name AS full_legal_name, k.channel_tag, k.status,
--   COALESCE((
--     SELECT balance_after FROM point_logs 
--     WHERE uid = k.uid 
--     ORDER BY created_at DESC, id DESC 
--     LIMIT 1
--   ), 0) AS current_points
-- FROM kocs k
-- WHERE k.status = 'active';

-- ============================================================
-- 2026-07-16 新增：等级体系 + 积分规则配置
-- ============================================================

-- 6. KOC 表新增等级字段
ALTER TABLE kocs ADD COLUMN IF NOT EXISTS tier TEXT DEFAULT 'certified'
  CHECK(tier IN ('certified','gold','platinum'));
ALTER TABLE kocs ADD COLUMN IF NOT EXISTS tier_updated_at TIMESTAMPTZ;
ALTER TABLE kocs ADD COLUMN IF NOT EXISTS tier_history TEXT DEFAULT '[]';
-- tier_history 格式: [{"month":"2026-07","tier":"platinum","monthly_points":35}]

-- 7. 活动/规则配置表（支持多期活动）
CREATE TABLE IF NOT EXISTS campaign_config (
  id SERIAL PRIMARY KEY,
  period TEXT NOT NULL UNIQUE,          -- "2026-07", "2026-08"
  name TEXT NOT NULL DEFAULT '',        -- "July Settlement"
  rules_json TEXT NOT NULL DEFAULT '{}', -- 完整规则 JSON
  points_cap INTEGER NOT NULL DEFAULT 40,  -- 月上限（统一40）
  submissions_open BOOLEAN DEFAULT false,
  redemption_open BOOLEAN DEFAULT false,
  submissions_close_at TIMESTAMPTZ,
  redemption_close_at TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 默认插入 7 月配置
INSERT INTO campaign_config (period, name, rules_json, points_cap)
VALUES ('2026-07', 'July Settlement', '{
  "engagement_platforms": ["Pinterest","Facebook","Instagram","X","Reddit"],
  "video_platforms": ["TikTok","YouTube"],
  "scoring": {
    "tiktok": {"200_views": 1, "400_views": 2},
    "youtube": {"200_views_20s_watchtime": 1, "400_views": 2},
    "engagement": {"40_engagements": 1, "80_engagements": 2}
  },
  "points_cap": 40,
  "consistent_creation_bonus": {"min_posts": 15},
  "tier_upgrade_threshold": 5
}', 40)
ON CONFLICT (period) DO NOTHING;
