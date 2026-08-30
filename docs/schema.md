# Local schema

The app's on-device cache, from `com.groupme.model.provider.GroupMeDatabaseHelper`.
Twenty tables behind a `ContentProvider`. Not the server's schema, but it is a good
starting shape for a client: it shows exactly which fields the app needs to render a
conversation without a network round trip.

`GroupMeDatabaseHelper` carries every historical migration, so most tables appear many
times in the decompiled source. What follows is the longest definition of each, which is
the current one.

## `albums`

```sql
CREATE TABLE IF NOT EXISTS albums (
  album_id TEXT PRIMARY KEY,
  title TEXT,
  created_at INTEGER,
  updated_at INTEGER,
  total_images INTEGER DEFAULT 0,
  total_videos INTEGER DEFAULT 0,
  total_views INTEGER DEFAULT 0,
  cover_image_url TEXT,
  event_id TEXT,
  conversation_id TEXT,
  creator_id TEXT,
  share_url TEXT,
  share_qr_code TEXT,
  event_start_at TEXT
);
```

## `chats`

```sql
CREATE TABLE IF NOT EXISTS chats (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  avatar_url TEXT,
  message_count INTEGER DEFAULT 0,
  attachment_count INTEGER DEFAULT 0,
  last_sender_name TEXT,
  last_message_text TEXT,
  last_message_created_at INTEGER,
  last_message_photo INTEGER NOT NULL DEFAULT 0,
  last_message_location INTEGER NOT NULL DEFAULT 0,
  last_message_collect INTEGER NOT NULL DEFAULT 0,
  last_message_video INTEGER NOT NULL DEFAULT 0,
  last_message_event INTEGER NOT NULL DEFAULT 0,
  last_message_poll INTEGER NOT NULL DEFAULT 0,
  last_message_vanishing_post INTEGER NOT NULL DEFAULT 0,
  last_emoji_placeholder TEXT,
  last_emoji_charmap TEXT,
  is_hidden INTEGER DEFAULT 0,
  created_at INTEGER,
  updated_at INTEGER,
  read_receipt_message_id TEXT,
  read_receipt_timestamp INTEGER NOT NULL DEFAULT 0,
  last_message_id INTEGER NOT NULL DEFAULT 0,
  last_read_message INTEGER NOT NULL DEFAULT 0,
  unread_count INTEGER NOT NULL DEFAULT 0,
  last_viewed_at INTEGER NOT NULL DEFAULT 0,
  last_message_document INTEGER NOT NULL DEFAULT 0,
  last_message_reply INTEGER NOT NULL DEFAULT 0,
  muted_until INTEGER,
  last_message_deleted_at INTEGER NOT NULL DEFAULT 0,
  last_message_deletion_actor TEXT,
  message_deletion_period INTEGER NOT NULL DEFAULT 0,
  is_dm_request INTEGER DEFAULT 0,
  message_request TEXT,
  last_events_fetched_at TEXT,
  message_edit_period INTEGER NOT NULL DEFAULT 0,
  last_message_media_type INTEGER,
  theme_id TEXT,
  theme_custom_url TEXT,
  is_synced_to_server INTEGER NOT NULL DEFAULT 0
);
```

```sql
CREATE INDEX idx_direct_messages ON chats (user_id,muted_until);
```

## `directory_groups`

```sql
CREATE TABLE IF NOT EXISTS directory_groups (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  group_type TEXT,
  description TEXT,
  image_url TEXT,
  creator_user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  muted_until INTEGER,
  office_mode INTEGER NOT NULL DEFAULT 0,
  share_url TEXT,
  share_code TEXT,
  member_count INTEGER DEFAULT 0,
  max_members INTEGER NOT NULL DEFAULT 50,
  directory_name TEXT,
  directory_id TEXT,
  require_approval INTEGER NOT NULL DEFAULT 0,
  require_join_question INTEGER NOT NULL DEFAULT 0,
  join_question TEXT,
  status TEXT,
  visibility TEXT,
  locations TEXT
);
```

## `documents`

```sql
CREATE TABLE IF NOT EXISTS documents (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  document_id TEXT NOT NULL,
  document_name TEXT NOT NULL,
  document_size INTEGER NOT NULL,
  mime_type TEXT_NOT_NULL
);
```

## `events`

```sql
CREATE TABLE IF NOT EXISTS events (_id INTEGER PRIMARY KEY AUTOINCREMENT,event_id INTEGER NOT NULL,conversation_id INTEGER NOT NULL,creator_id INTEGER NOT NULL,name TEXT NOT NULL,description TEXT,image_url TEXT,location TEXT,start_at TEXT NOT NULL,end_at TEXT,is_all_day INTEGER NOT NULL,timezone TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,deleted_at TEXT,going TEXT,not_going TEXT,maybe_going TEXT,reminders TEXT,scheduled_call INTEGER NOT NULL,rsvp_list TEXT,share_url TEXT,share_qr_code TEXT,visibility TEXT,directory_id INTEGER NOT NULL DEFAULT -1,is_top_level INTEGER NOT NULL DEFAULT 0,rsvp_deadline TEXT,end_time_set INTEGER NOT NULL DEFAULT 1,album_id TEXT,album_name TEXT,series_id TEXT,instance_index INTEGER,recurrence_rule TEXT,recurrence_end TEXT,capacity INTEGER,waitlist_enabled INTEGER NOT NULL DEFAULT 0,waitlist TEXT,links TEXT,aesthetics TEXT);;
```

```sql
CREATE INDEX IF NOT EXISTS idx_events_event_id ON events (event_id);
CREATE INDEX IF NOT EXISTS idx_events_series_id ON events (series_id);
```

## `gallery`

```sql
CREATE TABLE IF NOT EXISTS gallery (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  gallery_ts INTEGER NOT NULL,
  conversation_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  source_guid TEXT,
  sender_id TEXT NOT NULL,
  sender_name TEXT NOT NULL,
  sender_avatar_url TEXT,
  message_text TEXT,
  media_type INTEGER NOT NULL,
  media_url TEXT NOT NULL,
  media_preview_url TEXT,
  media_source_url TEXT,
  emoji_placeholder TEXT,
  emoji_charmap TEXT,
  favorited_by TEXT,
  document_id TEXT,
  document TEXT,
  local_document_url TEXT,
  blur_hash TEXT
);
```

```sql
CREATE INDEX idx_gallery ON gallery(conversation_id);
CREATE UNIQUE INDEX idx_gallery_messages ON gallery(conversation_id,message_id,media_url);
```

## `group_likes`

```sql
CREATE TABLE IF NOT EXISTS group_likes (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  source_guid TEXT,
  created_at INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  recipient_id TEXT,
  name TEXT NOT NULL,
  avatar_url TEXT,
  message_text TEXT,
  is_system INTEGER NOT NULL DEFAULT 0,
  favorited_by TEXT,
  photo_url TEXT,
  photo_url_list TEXT,
  photo_width INTEGER NOT NULL DEFAULT 0,
  photo_height INTEGER NOT NULL DEFAULT 0,
  photo_is_gif INTEGER NOT NULL DEFAULT 0,
  meme_source_url TEXT,
  meme_original_url_list TEXT,
  meme_original_uri_list TEXT,
  photo_uri TEXT,
  photo_uri_list TEXT,
  video_url TEXT,
  video_uri TEXT,
  video_start_time INTEGER NOT NULL DEFAULT 0,
  video_end_time INTEGER NOT NULL DEFAULT 0,
  preview_url TEXT,
  blur_hash TEXT,
  location_lat TEXT,
  location_lng TEXT,
  location_name TEXT,
  emoji_placeholder TEXT,
  emoji_charmap TEXT,
  send_status INTEGER NOT NULL DEFAULT 2,
  hidden INTEGER NOT NULL DEFAULT 0,
  autokicked_member TEXT,
  undeliverable_member_guids TEXT,
  mentions TEXT,
  is_mentioned INTEGER NOT NULL DEFAULT 0,
  event_id TEXT,
  event TEXT,
  poll TEXT,
  poll_id TEXT,
  sender_id TEXT,
  sender_type TEXT,
  reply_id TEXT,
  base_reply_id TEXT,
  document_id,
  document,
  local_document_url,
  filter INTEGER NOT NULL,
  pinned_at,
  pinned_by
);
```

```sql
CREATE INDEX IF NOT EXISTS idx_popular_messages_conversation_id ON group_likes (conversation_id);
CREATE INDEX IF NOT EXISTS idx_popular_messages_period ON group_likes (filter);
```

## `groups`

```sql
CREATE TABLE IF NOT EXISTS groups (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  group_type TEXT,
  group_category TEXT,
  message_count INTEGER DEFAULT 0,
  attachment_count INTEGER DEFAULT 0,
  image_url TEXT,
  creator_user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  nickname TEXT,
  membership_id TEXT,
  office_mode INTEGER NOT NULL DEFAULT 0,
  share_url TEXT,
  last_sender_name TEXT,
  last_message_text TEXT,
  last_sender_avatar_url TEXT,
  last_message_created_at INTEGER,
  last_message_updated_at INTEGER,
  last_message_photo INTEGER NOT NULL DEFAULT 0,
  last_message_location INTEGER NOT NULL DEFAULT 0,
  last_message_collect INTEGER NOT NULL DEFAULT 0,
  last_message_video INTEGER NOT NULL DEFAULT 0,
  last_message_event INTEGER NOT NULL DEFAULT 0,
  last_message_poll INTEGER NOT NULL DEFAULT 0,
  last_message_vanishing_post INTEGER NOT NULL DEFAULT 0,
  last_emoji_placeholder TEXT,
  last_emoji_charmap TEXT,
  last_message_id INTEGER NOT NULL DEFAULT 0,
  is_hidden INTEGER NOT NULL DEFAULT 0,
  last_message_mentioned INTEGER NOT NULL DEFAULT 0,
  last_read_message INTEGER NOT NULL DEFAULT 0,
  last_viewed_at INTEGER NOT NULL DEFAULT 0,
  unread_count INTEGER NOT NULL DEFAULT 0,
  child_unread_count INTEGER NOT NULL DEFAULT 0,
  max_memberships INTEGER NOT NULL DEFAULT 50,
  last_message_document INTEGER NOT NULL DEFAULT 0,
  last_message_reply INTEGER NOT NULL DEFAULT 0,
  share_code TEXT,
  muted_until INTEGER,
  theme_header_overlay_light TEXT,
  theme_header_overlay_dark TEXT,
  theme_avatar_overlay_light TEXT,
  theme_avatar_overlay_dark TEXT,
  theme_text_color_light TEXT,
  theme_text_color_dark TEXT,
  theme_stripe_color_light TEXT,
  theme_stripe_color_dark TEXT,
  theme_header_url_light TEXT,
  theme_header_url_dark TEXT,
  reaction_type TEXT,
  reaction_emoji_pack INTEGER,
  reaction_emoji_id INTEGER,
  require_approval INTEGER NOT NULL DEFAULT 0,
  require_join_question INTEGER NOT NULL DEFAULT 0,
  join_question TEXT,
  last_message_deleted_at INTEGER NOT NULL DEFAULT 0,
  last_message_deletion_actor TEXT,
  message_deletion_period INTEGER NOT NULL DEFAULT 0,
  message_deletion_mode TEXT,
  visibility TEXT,
  locations TEXT,
  parent_id TEXT,
  children_count INTEGER NOT NULL DEFAULT 0,
  parent_name TEXT,
  muted_children_count INTEGER NOT NULL DEFAULT 0,
  last_events_fetched_at TEXT,
  message_edit_period INTEGER NOT NULL DEFAULT 0,
  copilot_message_permission TEXT,
  last_message_media_type INTEGER,
  system_message_settings_all_notifications INTEGER,
  system_message_settings_categories TEXT,
  recap_enabled INTEGER NOT NULL DEFAULT 0,
  theme_id TEXT,
  theme_custom_url TEXT,
  expires_at INTEGER,
  matchup_game_id TEXT,
  matchup_sport TEXT,
  matchup_league TEXT,
  matchup_home_directory_id INTEGER DEFAULT 0,
  matchup_away_directory_id INTEGER DEFAULT 0,
  chaos_mode INTEGER NOT NULL DEFAULT 0,
  is_synced_to_server INTEGER NOT NULL DEFAULT 0
);
```

```sql
CREATE INDEX idx_groups ON groups (group_id,muted_until);
CREATE INDEX idx_groups_parent ON groups (parent_id);
```

## `media_attachments`

```sql
CREATE TABLE IF NOT EXISTS media_attachments (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  media_id TEXT NOT NULL UNIQUE,
  message_id TEXT NOT NULL,
  source_guid TEXT NOT NULL,
  type INTEGER NOT NULL,
  media_url TEXT,
  media_uri TEXT,
  blur_hash TEXT,
  preview_url TEXT,
  sent_state INTEGER NOT NULL DEFAULT 0,
  video_start_time INTEGER NOT NULL DEFAULT 0,
  video_end_time INTEGER NOT NULL DEFAULT 0,
  partial_image_content TEXT,
  partial_image_id TEXT,
  creator_id TEXT,
  creator_name TEXT,
  creator_avatar_url TEXT,
  conversation_id TEXT,
  created_at TEXT,
  updated_at TEXT,
  total_views REAL DEFAULT 0,
  source_type INTEGER NOT NULL DEFAULT 0,
  category INTEGER,
  user_id TEXT,
  duration INTEGER,
  peaks TEXT,
  transcript_url TEXT
);
```

```sql
CREATE INDEX idx_media_attachment ON media_attachments (source_guid);
CREATE INDEX idx_album_id ON media_attachments (message_id);
```

## `members`

```sql
CREATE TABLE IF NOT EXISTS members (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id TEXT NOT NULL,
  source_guid TEXT,
  user_id TEXT NOT NULL,
  member_id TEXT,
  nickname TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  is_muted INTEGER NOT NULL DEFAULT 0,
  auto_kicked INTEGER NOT NULL DEFAULT 0,
  image_url TEXT,
  phone_number TEXT,
  role TEXT,
  state TEXT,
  user_real_name TEXT,
  muted_until INTEGER,
  directory_short_name TEXT,
  directory_color TEXT
);
```

```sql
CREATE INDEX idx_group_members ON members (group_id);
CREATE INDEX idx_user_members ON members (user_id);
CREATE UNIQUE INDEX idx_group_member ON members (user_id, group_id);
```

## `membership_states`

```sql
CREATE TABLE IF NOT EXISTS membership_states (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id TEXT NOT NULL,
  state TEXT
);
```

## `message_reactions`

```sql
CREATE TABLE IF NOT EXISTS message_reactions (
  conversation_id TEXT NOT NULL,
  conversation_type INTEGER NOT NULL,
  message_id TEXT NOT NULL,
  reaction TEXT NOT NULL,
  reaction_type TEXT NOT NULL,
  user_id TEXT NOT NULL,
  PRIMARY KEY (message_id, user_id, conversation_id)
);
```

## `messages`

```sql
CREATE TABLE IF NOT EXISTS messages (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id TEXT NOT NULL,
  message_id TEXT UNIQUE,
  source_guid TEXT,
  created_at INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  recipient_id TEXT,
  name TEXT NOT NULL,
  avatar_url TEXT,
  message_text TEXT,
  is_system INTEGER NOT NULL DEFAULT 0,
  favorited_by TEXT,
  photo_url TEXT,
  photo_url_list TEXT,
  photo_width INTEGER NOT NULL DEFAULT 0,
  photo_height INTEGER NOT NULL DEFAULT 0,
  photo_is_gif INTEGER NOT NULL DEFAULT 0,
  meme_source_url TEXT,
  meme_original_url_list TEXT,
  meme_original_uri_list TEXT,
  photo_uri TEXT,
  photo_uri_list TEXT,
  video_url TEXT,
  video_uri TEXT,
  video_start_time INTEGER NOT NULL DEFAULT 0,
  video_end_time INTEGER NOT NULL DEFAULT 0,
  preview_url TEXT,
  blur_hash TEXT,
  location_lat TEXT,
  location_lng TEXT,
  location_name TEXT,
  emoji_placeholder TEXT,
  emoji_charmap TEXT,
  send_status INTEGER NOT NULL DEFAULT 2,
  hidden INTEGER NOT NULL DEFAULT 0,
  autokicked_member TEXT,
  undeliverable_member_guids TEXT,
  is_mentioned INTEGER NOT NULL DEFAULT 0,
  mentions TEXT,
  event_id TEXT,
  event TEXT,
  sender_id TEXT,
  sender_type TEXT,
  read INTEGER NOT NULL DEFAULT 0,
  document_id TEXT,
  document TEXT,
  local_document_url TEXT,
  poll_id TEXT,
  poll TEXT,
  reply_id TEXT,
  base_reply_id TEXT,
  deleted_at INTEGER NOT NULL DEFAULT 0,
  deletion_actor TEXT,
  pinned_at INTEGER NOT NULL DEFAULT 0,
  pinned_by TEXT,
  system_event TEXT,
  system_event_type TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0,
  pending_message_text TEXT,
  pending_mentions TEXT,
  pending_emoji_placeholder TEXT,
  pending_emoji_charmap TEXT,
  edit_status INTEGER NOT NULL DEFAULT 5,
  prompt_sender TEXT,
  is_partial_image INTEGER NOT NULL DEFAULT 0,
  media_type INTEGER,
  has_copilot_card INTEGER NOT NULL DEFAULT 0,
  vanishing_delivery_id TEXT,
  vanishing_replay_allowed INTEGER NOT NULL DEFAULT 0,
  vanishing_viewed_by TEXT,
  vanishing_media_deleted INTEGER NOT NULL DEFAULT 0
);
```

```sql
CREATE INDEX idx_messages ON messages (send_status,created_at,conversation_id,hidden,message_id,source_guid,user_id,autokicked_member,is_system);
CREATE INDEX idx_messages_id ON messages (message_id);
CREATE INDEX idx_messages_source ON messages (source_guid);
CREATE INDEX idx_conversation_id ON messages (conversation_id);
```

## `poll_options`

```sql
CREATE TABLE IF NOT EXISTS poll_options (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  poll_id INTEGER NOT NULL,
  option_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  votes INTEGER NOT NULL DEFAULT 0,
  voter_ids TEXT
);
```

## `polls`

```sql
CREATE TABLE IF NOT EXISTS polls (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  poll_id INTEGER NOT NULL,
  conversation_id INTEGER NOT NULL,
  owner_id TEXT NOT NULL,
  subject TEXT NOT NULL,
  expiration INTEGER NOT NULL,
  status TEXT,
  user_vote TEXT,
  last_modified INTEGER NOT NULL,
  visibility TEXT,
  type TEXT
);
```

## `powerup_categories`

```sql
CREATE TABLE IF NOT EXISTS powerup_categories (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  powerup_ids TEXT NOT NULL
);
```

## `powerups`

```sql
CREATE TABLE IF NOT EXISTS powerups (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  powerup_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  type TEXT NOT NULL,
  meta TEXT NOT NULL,
  is_dirty INTEGER NOT NULL DEFAULT 1,
  purchased INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0,
  store_assets_complete INTEGER NOT NULL DEFAULT 0,
  price TEXT,
  category TEXT,
  sku TEXT
);
```

## `ranked_contacts`

```sql
CREATE TABLE IF NOT EXISTS ranked_contacts (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  contact_id INTEGER NOT NULL UNIQUE,
  display_name TEXT,
  phone_numbers TEXT,
  emails TEXT,
  contact_photo_uri TEXT,
  is_favorited INTEGER NOT NULL DEFAULT 0,
  has_emoji INTEGER NOT NULL DEFAULT 0,
  has_relationship_label INTEGER NOT NULL DEFAULT 0,
  is_first_name_only INTEGER NOT NULL DEFAULT 0,
  has_multiple_phones INTEGER NOT NULL DEFAULT 0,
  has_address INTEGER NOT NULL DEFAULT 0,
  has_photo INTEGER NOT NULL DEFAULT 0,
  has_birthday INTEGER NOT NULL DEFAULT 0,
  is_on_groupme INTEGER NOT NULL DEFAULT 0,
  user_id TEXT,
  avatar_url TEXT,
  is_active_last_30_days INTEGER NOT NULL DEFAULT 0,
  mutual_connections INTEGER NOT NULL DEFAULT 0,
  client_score REAL NOT NULL DEFAULT 0,
  server_boost REAL NOT NULL DEFAULT 0,
  final_score REAL NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
);
```

## `relationships`

```sql
CREATE TABLE IF NOT EXISTS relationships (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  relationship_id TEXT NOT NULL UNIQUE,
  user_id TEXT NOT NULL UNIQUE,
  name TEXT,
  avatar_url TEXT,
  reason INTEGER,
  is_hidden INTEGER,
  phone_number TEXT,
  raw_contact_id TEXT,
  app_installed INTEGER,
  is_blocked INTEGER NOT NULL DEFAULT 0,
  is_active_last_30_days INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  created_at_iso8601 TEXT,
  updated_at_iso8601 TEXT
);
```

```sql
CREATE INDEX idx_relationships_user_id ON relationships (user_id);
```

## `user_directories`

```sql
CREATE TABLE IF NOT EXISTS user_directories (
  _id INTEGER PRIMARY KEY AUTOINCREMENT,
  directory_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  image_url TEXT,
  created_at INTEGER,
  updated_at INTEGER,
  last_queried_at INTEGER DEFAULT 0,
  member_count INTEGER DEFAULT 0,
  groups_count INTEGER,
  share_url TEXT,
  share_qr_url TEXT,
  short_name TEXT
);
```

