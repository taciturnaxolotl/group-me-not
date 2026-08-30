# Data models

Every GSON model shipped in the GroupMe Android APK, dumped from `com.groupme.api`
and `com.groupme.model`. Field names are the wire names: where the Java field carries
a `@SerializedName`, that name is used instead of the Java identifier.

Envelope classes (`*Envelope`, `*Response`) mirror the API's `{"response": ..., "meta": ...}`
wrapper. See [conventions](conventions.md).


### com/groupme/api/AccountRecoveryEnvelope.java
class AccountRecoveryEnvelope
  - response: Response
  class Methods
  class Response
    - code: String
    - long_pin: String
    - system_number: String

### com/groupme/api/AgeConfirmEnvelope.java
class AgeConfirmEnvelope
  - response: Response
  class Meta
  class Response
    - verification: Verification
  class Verification
    - code: String

### com/groupme/api/AgeGateResponse.java
class AgeGateResponse
  - response: Response
  class Meta
  class RecoveryVerification
    - code: String
  class Response
    - recovery_verification: RecoveryVerification

### com/groupme/api/AgeVerificationEnvelope.java
class AgeVerificationEnvelope
  - response: Response
  class Meta
  class Response
    - age: String

### com/groupme/api/BasicEnvelope.java
class BasicEnvelope
  - meta: Meta

### com/groupme/api/BatchReadReceiptRequest.java
class BatchReadReceiptRequest
  - receipts: List<Receipt>
  class Receipt
    - conversation_id: String
    - last_read_message_id: String

### com/groupme/api/BatchReadReceiptResponse.java
class BatchReadReceiptResponse
  - meta: Meta
  - response: Response
  class ReceiptResult
    - conversation_id: String
    - last_read_message_id: String
  class Response
    - receipts: List<ReceiptResult>

### com/groupme/api/Block.java
class Block
  - blocked_user_id: String
  class BlockArray
    - blocks: Block[]
  class BlockBetween
  class BlockBetweenResponse
  class BlockIndexResponse
    - response: BlockArray
  class BlockList

### com/groupme/api/CallDetails.java
class CallDetails
  - meta: Meta
  - response: Response
  class Response
    - expires_on: long
    - meeting_id: String
    - meeting_type: String
    - token: String

### com/groupme/api/CallRefreshToken.java
class CallRefreshToken
  - meta: Meta
  - response: Response
  class Response
    - expires_on: long
    - token: String

### com/groupme/api/CampusUserInfo.java
class CampusUserInfo
  - avatar_url: String
  - bio: String
  - graduation_year: String
  - id: String
  - majors: String[]
  - name: String
  - photo_urls: String[]
  - shared_group_ids: String[]
  - social_media_links: String[]
  class Response
    - users: CampusUserInfo[]
  class UsersResponse
    - meta: Meta
    - response: Response

### com/groupme/api/CampusUserMajor.java
class CampusUserMajor
  - assetId: String
  - glyph: String
  - id: int
  - name: String
  class Companion

### com/groupme/api/CancelEvictionEnvelope.java
class CancelEvictionEnvelope
  - response: Response
  class Meta
  class Response
    - verification: Verification
    class CancelEviction
    class Verification
      - code: String

### com/groupme/api/ChangePhoneNumber.java
class ChangePhoneNumber
  - meta: Meta
  - response: Response
  class Meta
    - code: int
  class Response
    - code_format: LoginResponse.CodeFormat
    - phone_number_change: PhoneNumberChange
    class PhoneNumberChange
      - id: String

### com/groupme/api/Chat.java
class Chat
  - created_at: long
  - is_hidden: boolean
  - last_message: Message
  - last_read_at: long
  - last_read_message_id: String
  - message_deletion_period: int
  - message_edit_period: long
  - messages_count: int
  - other_user: OtherUser
  - requires_approval: boolean
  - theme_custom_url: String
  - theme_id: String
  - unread_count: int
  - updated_at: long
  class IndexResponse
    - response: Chat[]
  class OtherUser
    - avatar_url: String
    - id: String
    - name: String
  class SingleResponse
    - response: Chat

### com/groupme/api/CopilotCardPayload.java
class CopilotCardPayload
  - flashcards: List<FlashcardItem>
  - quiz: List<QuizQuestion>
  - title: String
  - type: String

### com/groupme/api/CopilotCardScore.java
class CopilotCardScore
  - correct: int
  - total: int

### com/groupme/api/DMCallDetails.java
class DMCallDetails
  - meta: Meta
  - response: Response
  class Response
    - acs_user_id: String
    - userId: String

### com/groupme/api/Directory.java
class Directory
  - abbreviation: String
  - avatar_url: String
  - city: String
  - color: String
  - country: String
  - created_at: String
  - groups_count: int
  - id: String
  - logo_url: String
  - members_count: int
  - name: String
  - reason_code: String
  - share_qr_code_url: String
  - share_url: String
  - short_name: String
  - state: String
  - type: String
  - updated_at: String
  class DirectoryEnvelope
    - response: Directory[]
  class DirectoryPreviewEnvelope
    - response: Envelope
    class Envelope
      - directory: Directory
  class NearbyDirectoriesEnvelope
    - response: Response
    class Response
      - directories: Directory[]
  class UserDirectoriesEnvelope
    - response: Directory[]

### com/groupme/api/DirectoryDetailsResponse.java
class DirectoryDetailsResponse
  - response: DirectoryDetails
  class DirectoryDetails
    - avatar_url: String
    - color: String
    - country: String
    - id: String
    - name: String
    - short_name: String

### com/groupme/api/DirectoryGroup.java
class DirectoryGroup
  - group_id: String
  - members_count: int
  - membership: Membership
  class GroupEnvelope
    - response: DirectoryGroup[]
  class Membership
    - state: String

### com/groupme/api/DirectoryMemberProfile.java
class DirectoryMemberProfile
  - campus_profile_visibility: String
  - directory_id: Integer
  - graduation_year: String
  - id: String
  - major_ids: List<String>
  - userId: Long

### com/groupme/api/DirectoryMemberProfileResponse.java
class DirectoryMemberProfileResponse
  - meta: Meta
  - response: DirectoryMemberProfile

### com/groupme/api/DirectoryVerificationEnvelope.java
class DirectoryVerificationEnvelope
  - meta: Meta
  - response: Response
  class Method
  class Response
    - id: String
    - verification: Verification
  class Verification
    - code: String

### com/groupme/api/Document.java
class Document
  - file_name: String
  - file_size: long
  - mime_type: String
  class SingleResponse
    - file_data: Document
    - file_id: String

### com/groupme/api/EmojiMeta.java
class EmojiMeta
  - icon_download_complete: boolean
  - icon: PowerUpPackPart[]
  - inline_download_complete: boolean
  - inline: PowerUpPackPart[]
  - keyboard_download_complete: boolean
  - keyboard: PowerUpPackPart[]
  - pack_id: int
  - sticker_download_complete: boolean
  - sticker: PowerUpPackPart[]
  - transliterations: String[]

### com/groupme/api/Event.java
class Event
  - aesthetics: EventAesthetics
  - album: Album
  - capacity: Integer
  - conversation_id: String
  - created_at: String
  - creator_id: String
  - deleted_at: String
  - description: String
  - directory_id: int
  - end_at: String
  - end_at_set: Boolean
  - event_id: String
  - going: String[]
  - imageUri: String
  - image_url: String
  - instance_index: Integer
  - is_all_day: Boolean
  - is_top_level: Boolean
  - links: List<EventLinkPayload>
  - location: Location
  - maybe_going: String[]
  - name: String
  - not_going: String[]
  - recurrence_end: String
  - reminders: int[]
  - rrule: String
  - rsvp_deadline: String
  - rsvp_list: HashMap<String, String>
  - scheduled_call: Boolean
  - series_id: String
  - share_qr_code: String
  - share_url: String
  - start_at: String
  - timezone: String
  - updated_at: String
  - visibility: String
  - waitlist_enabled: Boolean
  - waitlisted: String[]
  class Album
    - album_id: String
    - title: String
  class CampusEventVisibility
    - visibility: String
  class Location
    - address: String
    - lat: Double
    - lng: Double
    - name: String
  class Response
    - response: EventListResponse
    class EventListResponse
      - events: Event[]
      - next: String
  class SingleResponse
    - response: Payload
    class Payload
      - event: Event
      - message: Message

### com/groupme/api/EventAesthetics.java
class EventAesthetics
  - effect: String
  - font: String
  - theme: String

### com/groupme/api/EventBannerList.java
class EventBannerList
  - category: String
  - isDefault: String
  - largeImage: String
  - name: String
  - tags: List<String>
  - thumbnail: String
  class Companion

### com/groupme/api/EventLinkPayload.java
class EventLinkPayload
  - name: String
  - type: String
  - url: String

### com/groupme/api/EventNonMembers.java
class EventNonMembers
  - meta: Meta
  - response: Response

### com/groupme/api/EventPreview.java
class EventPreview
  - meta: Meta
  - response: Response
  class Meta
    - code: int
  class Response
    - event: Event

### com/groupme/api/ExtendedPoll.java
class ExtendedPoll
  - avatar_url: String
  - sender_name: String

### com/groupme/api/FayeMessage.java
class FayeMessage
  class ChatDeletePayload
    - chat_id: String
  class DMFavoritePayload
    - direct_message: DirectMessage
    - userId: String
  class DMReactionsPayload
    - direct_message: DMReaction
    - reactions: Message.Reaction[]
    class DMReaction
      - chat_id: String
      - id: String
  class Data
    - subject: JsonObject
    - userId: String
  class DirectMessage
    - chat_id: String
    - name: String
    - id: String
  class FavoritePayload
    - line: FavoritedLine
    - userId: String
  class FavoritedLine
    - groupId: String
    - group_name: String
    - id: String
  class GroupBotSettingsPayload
    - bot_settings: BotSettings
    - conversation_id: String
    class BotSettings
      - copilot: Copilot
      class Copilot
        - message_permission: String
  class GroupMessageDeletionModePayload
    - conversation_id: String
    - message_deletion_mode: String[]
  class GroupMuteStateSyncPayload
    - parent_id: String
    - muted_children: JsonObject
    - muted_until: long
  class PollVoteResponse
    - poll: Poll.PollEnvelope
  class ReactionsPayload
    - line: ReactionLine
    - reactions: Message.Reaction[]
    class ReactionLine
      - groupId: String
      - id: String
  class ReadReceipt
    - chat_id: String
    - messageId: String
    - read_at: long
    - userId: String

### com/groupme/api/FlashcardItem.java
class FlashcardItem
  - back: String
  - front: String

### com/groupme/api/Gallery.java
class Gallery
  - gallery_ts: String
  class GalleryResponse
    - response: Response
    class Response
      - messages: Gallery[]

### com/groupme/api/Group.java
class Group
  - active_call_participants: Integer
  - avatar_url: String
  - bot_settings: BotSettings
  - chaos: boolean
  - children_count: int
  - created_at: long
  - creator_id: String
  - creator_user_id: String
  - description: String
  - directories: Directories[]
  - expires_at: long
  - group_category: String
  - group_size: int
  - id: String
  - image_url: String
  - is_hidden: boolean
  - join_question: JoinQuestion
  - last_read_at: long
  - last_read_message_id: String
  - like_icon: Reaction
  - locations: Location[]
  - matchup: Matchup.MatchupDetails
  - max_members: int
  - members: Member[]
  - membership_state: String
  - message_deletion_mode: String[]
  - message_deletion_period: int
  - message_edit_period: int
  - messages: Messages
  - muted_children_count: int
  - muted_until: long
  - name: String
  - office_mode: boolean
  - recap_enabled: boolean
  - requires_approval: boolean
  - requires_campus_verification: boolean
  - selected: boolean
  - share_qr_code_url: String
  - share_url: String
  - show_join_question: boolean
  - sms_user_count: int
  - system_message_settings: SystemMessageSettings
  - theme_custom_url: String
  - theme_id: String
  - type: String
  - unread_count: int
  - updated_at: long
  - visibility: String
  class BotSettings
    - copilot: CopilotBotSettings
  class ChangeOwnerResponse
    - response: Response
    class Meta
    class Response
      - results: Result[]
    class Result
      - status: String
  class CopilotBotSettings
    - message_permission: String
  class Directories
    - directory_id: int
    - directory_name: String
    - directory_short_name: String
  class GroupPreviewResponse
    - response: Response
    class Response
      - children_count: int
      - join_question: JoinQuestion
      - show_join_question: boolean
      - updated_at: String
  class IndexResponse
    - response: Group[]
  class JoinGroupPreviewResponse
    - response: Response
    class GroupPreview
      - members_count: int
    class Response
      - group: GroupPreview
  class JoinGroupResponse
    - meta: Meta
    - response: Response
    class Meta
      - details: Details
      class Details
        - rejection_details: RejectionDetails
        - rejection_reason: String
      class RejectionDetails
        - days_remaining: int
        - hours_remaining: int
    class Response
      - group: Group
  class JoinQuestion
    - text: String
    - type: String
  class MembershipResponse
    - response: Response
    class Meta
    class Response
      - membership: Member
  class Messages
    - count: int
    - last_message_created_at: long
    - last_message_id: String
    - last_message_updated_at: long
    - preview: Preview
  class Preview
    - attachments: Message.Attachment[]
    - deleted_at: long
    - deletion_actor: String
    - event: Message.Event
    - image_url: String
    - nickname: String
    - text: String
  class Reaction
    - pack_id: int
    - pack_index: int
    - type: String
  class SearchGroupsResponse
    - response: Response
    class GroupInfo
      - avatar_url: String
      - category: String
      - children_count: int
      - description: String
      - directories: Matchup.MatchupDirectory[]
      - directory_id: String
      - expires_at: long
      - group_category: String
      - group_type: String
      - id: String
      - locations: Location[]
      - matchup: Matchup.MatchupDetails
      - max_members: int
      - members_count: int
      - membership_state: String
      - name: String
    class Response
      - directories: GroupInfo[]
      - nearby: GroupInfo[]
      - popular: GroupInfo[]
      - trending: GroupInfo[]
  class SingleResponse
    - response: Group
  class SystemMessageSettings
    - all_notifications: boolean
    - categories: Categories
    class Categories
      - albums: String[]
      - events: String[]
      - join_leave: String[]
  class UpdateRollResponse
    - meta: Meta
    class Meta
      - code: int
    class Response

### com/groupme/api/HideFormerGroupResponse.java
class HideFormerGroupResponse
  - meta: Meta
  - response: Response
  class Response
    - groupId: String
    - hidden: boolean

### com/groupme/api/ImageStyleRemixSuggestion.java
class ImageStyleRemixSuggestion
  - id: String
  - prompt: String
  - title: String

### com/groupme/api/Interest.java
class Interest
  - assetId: String
  - glyph: String
  - id: int
  - name: String
  class Companion

### com/groupme/api/InterestCategory.java
class InterestCategory
  - assetId: String
  - entries: Interest[]
  - glyph: String
  - id: int
  - name: String
  class Companion

### com/groupme/api/JoinRequestNotificationPayload.java
class JoinRequestNotificationPayload
  - key: String
  - meta: JoinRequestNotificaionMetadata
  - notification_text: String
  class JoinQuestion
  class JoinQuestionAnswer
    - response: String
  class JoinReason
    - answer: JoinQuestionAnswer
    - question: JoinQuestion
  class JoinRequestNotificaionMetadata
    - group_id: String
    - group_name: String
    - pending_member_id: long
    - pending_member_name: String
    - reason: JoinReason

### com/groupme/api/Like.java
class Like
  - direct_message: Message
  - line: Message
  - notificationText: String
  - reaction: Message.Reaction
  - title: String
  - user_id: String

### com/groupme/api/Location.java
class Location
  - country_code: String
  - country_region: String
  - country_subdivision: String
  - full_address: String
  - group_id: String
  - id: String
  - latitude: double
  - locality: String
  - longitude: double
  - name: String
  - postal_code: String
  - signature: String
  class GetGroupLocationsResponse
    - response: Location[]
  class Point
    - latitude: double
    - longitude: double
  class SearchLocationResponse
    - response: Location[]

### com/groupme/api/LoginNoPhoneResponseEnvelope.java
class LoginNoPhoneResponseEnvelope
  - response: Response
  class Response
    - code: String
    - long_pin: String
    - system_number: String

### com/groupme/api/LoginResponse.java
class LoginResponse
  - meta: Meta
  - response: Response
  class CodeFormat
    - charset: String
    - max_length: Integer
    - min_length: Integer
  class Meta
    - code: int
  class Response
    - access_token: String
    - cancel_url: String
    - image_url: String
    - reason: String
    - user_id: String
    - user_name: String
    - verification: Verification
  class Verification
    - code: String
    - code_format: CodeFormat
    - long_pin: String
    - methods: MfaChannelEnvelope.Methods
    - system_number: String
    - type: String

### com/groupme/api/MarkAllReadResponse.java
class MarkAllReadResponse
  - meta: Meta
  - response: Response
  class MarkReadReceipt
    - conversation_id: String
    - messageId: String
    - read_at: long
  class Response
    - receipt_list: MarkReadReceipt[]

### com/groupme/api/Matchup.java
class Matchup
  - directories: MatchupDirectory[]
  - expires_at: long
  - group_category: String
  - groupId: String
  - group_name: String
  - image_url: String
  - matchup: MatchupDetails
  - max_members: int
  - members_count: int
  class Companion
  class MatchupDetails
    - away: MatchupTeam
    - game_scheduled_at: long
    - home: MatchupTeam
    - game_id: String
    - sport: String
    - league: String
  class MatchupDirectory
    - directory_id: int
    - directory_name: String
    - directory_short_name: String
  class MatchupTeam
    - directory_id: int
    - team_id: String
  class MatchupsEnvelope
    - response: MatchupsResponse
  class MatchupsResponse
    - matchups: Matchup[]

### com/groupme/api/Member.java
class Member
  - autokicked: boolean
  - callee_user_name: String
  - caller_user_id: String
  - caller_user_name: String
  - child_state: Map<String, ChildState>
  - directory_color: String
  - directory_short_name: String
  - email: String
  - guid: String
  - id: String
  - image_url: String
  - muted: boolean
  - muted_until: String
  - name: String
  - nickname: String
  - phone_number: String
  - recap_enabled: boolean
  - roles: String[]
  - sports_chat_team: String
  - state: String
  - updated_at: long
  - user_id: String
  class AddMemberFailure
    - code: int
  class AddMemberResponse
    - meta: Meta
    - response: Response
    class Meta
      - code: int
    class Response
      - results_id: String
  class AddMemberResults
    - response: Response
    class Response
      - failed: AddMemberFailure[]
      - members: Member[]
  class ChildState
    - muted_until: String
    - recap_enabled: boolean
  class FormerMembersResult
    - response: Response
    class Response
      - memberships: Member[]
  class UpdateMemberResponse
    - response: Member

### com/groupme/api/MembershipState.java
class MembershipState
  - group_id: String
  - state: String
  class MembershipStatesResponse
    - response: MembershipState[]
    class Meta

### com/groupme/api/Message.java
class Message
  - attachments: Attachment[]
  - avatar_url: String
  - chat_id: String
  - created_at: long
  - deleted_at: long
  - deletion_actor: String
  - event: Event
  - favorited_by: String[]
  - group_id: String
  - id: String
  - location: Location
  - name: String
  - parent_id: String
  - picture_url: String
  - pinned_at: long
  - pinned_by: String
  - reactions: Reaction[]
  - read: boolean
  - recipient_id: String
  - sender_id: String
  - sender_type: String
  - source_guid: String
  - system: boolean
  - text: String
  - updated_at: long
  - user_id: String
  class Album
    - album_id: String
    - album_title: String
    - media_count: int
    - media_types: String[]
    - sender_avatar_url: String
    - sender_id: String
    - sender_name: String
    - share_url: String
  class Attachment
    - base_reply_id: String
    - blur_hash: String
    - card_id: String
    - card_type: String
    - category: String
    - charmap: int[][]
    - content: String
    - delivery_id: String
    - duration: int
    - event_id: String
    - file_id: String
    - guids: String[]
    - id: String
    - lat: String
    - lng: String
    - loci: int[][]
    - media_deleted: boolean
    - name: String
    - payload: CopilotCardPayload
    - peaks: String
    - placeholder: String
    - poll_id: String
    - preview_url: String
    - prompt_sender: String
    - replay_allowed: boolean
    - reply_id: String
    - source_score: CopilotCardScore
    - source_url: String
    - source_user_id: String
    - source_user_name: String
    - state: String
    - title: String
    - transcript_url: String
    - type: String
    - url: String
    - user_id: String
    - user_ids: String[]
    - view: String
    - viewed_by: String[]
  class DirectMessageIndexResponse
    - error: String
    - response: Response
    class MessageRequest
      - shared_groups: SharedGroup[]
    class ReadReceipt
      - message_id: String
      - read_at: long
    class Response
      - message_request: MessageRequest
      - direct_messages: Message[]
      - read_receipt: ReadReceipt
  class EditMessageErrorResponse
    - meta: Meta
  class Event
    - data: LocalizedData
    - type: String
  class GroupIndexResponse
    - error: String
    - response: Response
    class Response
      - messages: Message[]
  class IndexResponse
  class LeaderboardEntryData
    - rank: int
    - score: CopilotCardScore
    - userId: String
    - userName: String
  class LocalizedData
    - added_users: Member[]
    - adder_user: Member
    - album: Album
    - avatar_url: String
    - away_score: String
    - bing_game_center_url: String
    - body: String
    - call_duration: long
    - card_id: String
    - card_type: String
    - date: String
    - deeplink: String
    - deleted_at: long
    - deletion_actor: String
    - display: String
    - entries: List<LeaderboardEntryData>
    - event: com.groupme.api.Event
    - game_id: String
    - home_score: String
    - league: String
    - like_icon: ReactionIcon
    - member: Member
    - message: MessageEdits
    - message_edit_period: int
    - message_id: String
    - minute: String
    - moment_type: String
    - name: String
    - new_owner: Member
    - old_owner: Member
    - options: Poll.Data.Option[]
    - penalty_shootout: SportsPenaltyShootout
    - period: String
    - pinned_at: long
    - pinned_by: String
    - play_clock: String
    - player_image_url: String
    - player_name: String
    - player_short_name: String
    - plays: String
    - points: Integer
    - points_source: String
    - poll: SystemMessagePoll
    - quarter: Integer
    - removed_user: Member
    - role: String
    - season_year: String
    - sport: String
    - subgroup_avatar_url: String
    - subgroup_description: String
    - subgroup_id: String
    - subgroup_topic: String
    - team_id: String
    - thumbnail_url: String
    - title: String
    - topic: String
    - type: String
    - updated_at: long
    - updated_fields: ArrayList<String>
    - user: Member
    - video_url: String
    - videos: SportsMomentVideo[]
    - yards: String
  class Location
    - lat: String
    - lng: String
    - name: String
  class MessageEdits
    - attachments: Attachment[]
    - text: String
  class PinnedPreviewDMResponse
    class Response
      - direct_message: Message
  class PinnedPreviewGroupResponse
    class Response
  class PinnedPreviewResponse
  class Reaction
    - code: String
    - pack_id: int
    - pack_index: int
    - type: String
    - user_ids: String[]
  class ReactionIcon
    - pack_id: int
    - pack_index: int
  class SendMessageResponse
    - meta: Meta
    - response: Response
    class Meta
      - code: int
    class Response
      - direct_message: Message
      - message: Message
  class SingleMessageResponse
    - response: Response
    class Response
      - message: Message
  class SportsMomentVideo
    - thumbnail_url: String
    - title: String
    - url: String
  class SportsPenaltyKick
    - player: String
    - scored: boolean
  class SportsPenaltyRound
    - away: SportsPenaltyKick
    - home: SportsPenaltyKick
    - score_label: String
  class SportsPenaltyShootout
    - away_score: int
    - away_score_display: String
    - first_to_kick: String
    - home_score: int
    - home_score_display: String
    - rounds: SportsPenaltyRound[]
  class SystemMessagePoll
    - id: String
    - subject: String

### com/groupme/api/MessageReaction.java
class MessageReaction
  - assetId: String
  - glyph: String
  class Companion

### com/groupme/api/Meta.java
class Meta
  - code: int
  - errors: String[]

### com/groupme/api/MfaChannelEnvelope.java
class MfaChannelEnvelope
  - meta: Meta
  - response: Response
  class Meta
    - code: int
  class Methods
    - email: String
    - sms: String
  class Response
    - verification: Verification
  class Verification
    - code: String
    - code_format: LoginResponse.CodeFormat
    - long_pin: String
    - methods: Methods
    - status: String
    - system_number: String

### com/groupme/api/MfaEnvelope.java
class MfaEnvelope
  - response: Response
  class AccessToken
    - access_token: String
    - user: User
    - user_id: String
    - user_name: String
  class Meta
  class Mfa
    - backup_code: String
  class Response
    - access_token: AccessToken
    - mfa: Mfa
  class User
    - avatar_url: String

### com/groupme/api/PasswordResetResponse.java
class PasswordResetResponse
  - response: Response
  class Response
    - masked_email: String

### com/groupme/api/PinVerificationEnvelope.java
class PinVerificationEnvelope
  - meta: Meta
  - response: Response
  class Response
    - remaining_attempts: int

### com/groupme/api/PinnedConversationsResponse.java
class PinnedConversationsResponse
  - response: Response
  class Response
    - pinned_conversation_ids: String[]

### com/groupme/api/Poll.java
class Poll
  - data: Data
  - user_votes: String[]
  class CastVoteResponse
    - response: Response
    class Response
      - poll: PollEnvelope
  class CreatePollResponse
    - meta: Meta
    - response: Response
    class Meta
      - code: int
    class Response
      - message: Message
      - poll: PollEnvelope
  class Data
    - conversation_id: String
    - expiration: long
    - id: String
    - last_modified: long
    - options: Option[]
    - owner_id: String
    - status: String
    - subject: String
    - type: String
    - visibility: String
    class Option
      - id: String
      - poll_id: String
      - title: String
      - voter_ids: String[]
      - votes: int
  class EndPollResponse
    - response: Response
    class Response
      - poll: PollEnvelope
  class GetAllPollsResponse
    - response: Response
    class Response
      - continuation_token: String
      - polls: PollEnvelope[]
  class PollEnvelope
    - user_vote: String
  class RefreshPollResponse
    - response: Response
    class Response
      - poll: PollEnvelope

### com/groupme/api/PowerUp.java
class PowerUp
  - created_at: long
  - description: String
  - id: String
  - meta: PowerUpMeta
  - name: String
  - order: int
  - purchased: boolean
  - screenshots: PowerUpPackPart[]
  - store_assets_complete: boolean
  - store_icon: PowerUpPackPart[]
  - type: String
  - updated_at: long
  class PowerUpPurchasesResponse
    - purchases: String[]
  class PowerUpResponse
    - categories: PowerUpCategory[]
    - powerups: PowerUp[]

### com/groupme/api/PowerUpCategory.java
class PowerUpCategory
  - description: String
  - id: String
  - name: String
  - powerups: String[]
  - updated_at: long

### com/groupme/api/PowerUpMeta.java
class PowerUpMeta
  - mType: String

### com/groupme/api/PowerUpPackPart.java
class PowerUpPackPart
  - density: int
  - image_url: String
  - x: int
  - y: int
  - zip_url: String

### com/groupme/api/Profile.java
class Profile
  - access_token: String
  - avatar_url: String
  - bio: String
  - birth_date_set: boolean
  - campus_profile_visibility: String
  - created_at: long
  - directories: Directory[]
  - email: String
  - facebook_connected: boolean
  - friend_suggestable: Boolean
  - graduation_year: String
  - id: String
  - image_url: String
  - interests: ArrayList<Integer>
  - major_codes: ArrayList<Integer>
  - mfa: MultiFactorAuth
  - name: String
  - phone_number: String
  - photo_urls: ArrayList<String>
  - prompt_for_survey: boolean
  - share_qr_code_url: String
  - share_url: String
  - show_age_gate: boolean
  - sleep_until: long
  - sms: boolean
  - song_url: String
  - tags: String[]
  - twitter_connected: boolean
  class Directory
    - name: String
    - short_name: String
  class LegacyResponse
    - meta: Meta
    - response: Response
    class Meta
      - errors: String[]
    class Response
      - access_token: String
      - directories: Directory[]
      - graduation_year: String
      - interests: ArrayList<Integer>
      - major_codes: ArrayList<Integer>
      - mfa: MultiFactorAuth
      - photo_urls: ArrayList<String>
      - user: Profile
  class MfaChannel
  class MultiFactorAuth
    - backup_code: String
    - channels: MfaChannel[]
    - enabled: boolean
  class Response
    - response: Profile

### com/groupme/api/ProfileSharingResponse.java
class ProfileSharingResponse
  - share_qr_code_url: String
  - share_url: String
  class Response
    - response: ProfileSharingResponse

### com/groupme/api/PromptSuggestion.java
class PromptSuggestion
  - assetId: String
  - collections: List<String>
  - glyph: String
  - id: String
  - prompt: String
  - title: String
  - topics: String[]

### com/groupme/api/PushRegistration.java
class PushRegistration
  - registration_id: String
  class Response
    - response: Payload
    class Payload
      - push_registration: PushRegistration

### com/groupme/api/QuizQuestion.java
class QuizQuestion
  - answer: int
  - explanation: String
  - hint: String
  - options: List<String>
  - question: String
  - topics: List<String>
  - type: String

### com/groupme/api/R.java
class R
  class string
    - app_name: int

### com/groupme/api/ReadReceiptResponse.java
class ReadReceiptResponse
  - meta: Meta
  - response: Response
  class Response
    - conversation_id: String
    - last_read_message_id: String

### com/groupme/api/ReadReceiptsResponse.java
class ReadReceiptsResponse
  - meta: Meta
  - response: Response
  class ReadReceipt
    - conversation_id: String
    - last_read_message_id: String
  class Response
    - receipts: ReadReceipt[]

### com/groupme/api/RecapNotificationPayload.java
class RecapNotificationPayload
  - data: Data
  - notification: Notification
  class Data
    - badge_label: String
    - groupId: String
    - message_count: String
    - summary_id: String
    - type: String
  class Notification
    - body: String
    - subtitle: String
    - title: String

### com/groupme/api/RecapPayload.java
class RecapPayload
  - meta: Meta
  - response: Response
  class Recap
    - expires_at: String
    - generated_at: String
    - groupId: String
    - group_name: String
    - message_count: int
    - preview: String
    - summary: String
  class Response
    - recap: Recap

### com/groupme/api/RecapTriggerResponse.java
class RecapTriggerResponse
  - meta: Meta
  - response: Response
  class Response
    - estimated_delivery_seconds: Integer
    - retry_after_seconds: Integer
    - status: String

### com/groupme/api/Registration.java
class Registration
  - avatar_url: String
  - email: String
  - id: String
  - long_pin: String
  - mfa: boolean
  - name: String
  - password: String
  - phone_number: String
  - system_number: String
  class Response
    - response: ActualResponse
    class ActualResponse
      - access_token: String
      - mfa: Profile.MultiFactorAuth
      - registration: Registration
      - user: Profile
    class Meta

### com/groupme/api/Relationship.java
class Relationship
  - app_installed: boolean
  - avatar_url: String
  - blocked: boolean
  - created_at: long
  - created_at_iso8601: String
  - direct_message_capable: boolean
  - guid: String
  - hidden: boolean
  - id: String
  - is_active_last_30_days: boolean
  - name: String
  - phone_number: String
  - reason: int
  - updated_at: long
  - updated_at_iso8601: String
  - user_id: String
  class ImportContactResponse
    - response: Response
    class Response
      - batch_id: String
  class IndexResponse
    - response: Relationship[]
  class UserResponse
    - response: Response
    class Response
      - shared_groups: SharedGroup[]
      - user: Relationship

### com/groupme/api/Reply.java
class Reply
  - base_id: String
  - id: String

### com/groupme/api/Response.java
class Response
  - event: Event
  - group: Group
  - is_event_request: boolean
  - membershipState: MembershipState
  - share_token: String

### com/groupme/api/ResponseEnvelope.java
class ResponseEnvelope
  - response: T

### com/groupme/api/SearchCampusResponse.java
class SearchCampusResponse
  - events: CampusEventsInfo[]
  - newest: Group.SearchGroupsResponse.GroupInfo[]
  - trending: Group.SearchGroupsResponse.GroupInfo[]
  - users: CampusUserInfo[]

### com/groupme/api/SearchCampusResponseEnvelope.java
class SearchCampusResponseEnvelope
  - meta: Meta
  - response: SearchCampusResponse

### com/groupme/api/SeriesInfo.java
class SeriesInfo
  - active_instances: Integer
  - creator_id: String
  - going: List<String>
  - image_url: String
  - instances: List<SeriesInstance>
  - is_cancelled: boolean
  - is_online_event: boolean
  - maybe_going: List<String>
  - name: String
  - not_going: List<String>
  - recurrence_end: String
  - recurrence_rule: String
  - rsvp_list: HashMap<String, String>
  - series_card_id: String
  - series_id: String
  - total_instances: Integer
  class Response
    - response: SeriesInfo

### com/groupme/api/SeriesInstance.java
class SeriesInstance
  - deleted_at: String
  - event_id: String
  - instance_index: int
  - is_series_card: boolean
  - start_at: String

### com/groupme/api/SharedGroup.java
class SharedGroup
  - group_avatar: String
  - id: String
  - group_name: String

### com/groupme/api/SportsEvent.java
class SportsEvent
  - away: SportsEventTeam
  - away_score: String
  - bing_game_center_url: String
  - clock: String
  - ended_at: String
  - game_id: String
  - game_type: String
  - goals: List<SportsEventGoal>
  - home: SportsEventTeam
  - home_score: String
  - join_available_at: String
  - league: String
  - period: String
  - period_scores: List<SportsEventPeriodScore>
  - post_match_label: String
  - season_year: String
  - sport: String
  - start_time: String
  - state: String
  - stats: List<SportsEventStat>
  - team_stats: Object
  - timeline: List<SportsEventTimelineEntry>
  - tournament_title: String

### com/groupme/api/SportsEventEnvelope.java
class SportsEventEnvelope
  - response: List<SportsEventSubscription>

### com/groupme/api/SportsEventGoal.java
class SportsEventGoal
  - minute: String
  - minute_text: String
  - scorer_name: String
  - scorer_short_name: String
  - side: String

### com/groupme/api/SportsEventPeriodScore.java
class SportsEventPeriodScore
  - away_score: String
  - home_score: String
  - period_label: String

### com/groupme/api/SportsEventStat.java
class SportsEventStat
  - away_display: String
  - away_fraction: Double
  - home_display: String
  - home_fraction: Double
  - label: String

### com/groupme/api/SportsEventSubscription.java
class SportsEventSubscription
  - active: Boolean
  - event: SportsEvent
  - expires_at: Long
  - subscribed_at: String
  - subscription_id: Integer

### com/groupme/api/SportsEventTeam.java
class SportsEventTeam
  - brand_color: String
  - color: String
  - country_code: String
  - logo_url: String
  - name: String
  - record: String
  - score: String
  - short: String
  - team_id: String
  - win_probability: Double

### com/groupme/api/SportsEventTimelineEntry.java
class SportsEventTimelineEntry
  - away_score: String
  - bing_game_center_url: String
  - body: String
  - clock: String
  - display: String
  - home_score: String
  - minute: String
  - period: String
  - player: String
  - player_short_name: String
  - plays: Integer
  - points: Integer
  - sequence: Integer
  - team_id: String
  - type: String
  - yards: Integer

### com/groupme/api/SportsEventVenue.java
class SportsEventVenue
  - country_code: String

### com/groupme/api/Topic.java
class Topic
  - avatar_url: String
  - created_at: long
  - creator_user_id: String
  - description: String
  - id: String
  - like_icon: Group.Reaction
  - message_edit_period: int
  - messages: Group.Messages
  - muted_until: long
  - parent_id: String
  - recap_enabled: boolean
  - theme_custom_url: String
  - theme_id: String
  - topic: String
  - type: String
  - updated_at: long
  class TopicCreateResponse
    - response: Topic
  class TopicGetResponse
    - response: Topic
  class TopicIndexResponse
    - response: Topic[]

### com/groupme/api/UserCalendarEventResponse.java
class UserCalendarEventResponse
  - conversation_id: String
  - conversation_name: String
  - created_at: String
  - creator_id: String
  - end_at: String
  - end_at_set: Boolean
  - event_id: String
  - image_url: String
  - is_all_day: boolean
  - my_rsvp_status: String
  - name: String
  - rrule: String
  - rsvp_counts: RsvpCounts
  - rsvp_deadline: String
  - scheduled_call: boolean
  - series_id: String
  - start_at: String
  - updated_at: String
  class RsvpCounts

### com/groupme/api/UserCalendarEventsResponse.java
class UserCalendarEventsResponse
  - response: EventsPayload
  class EventsPayload
    - events: List<UserCalendarEventResponse>
    - next_page: String
    - next_page_url: String

### com/groupme/api/Venue.java
class Venue
  - isCurrentLocation: boolean
  class Companion
  class VenuesResponse
    - meta: Meta
    - response: Venue[]

### com/groupme/api/presence/GroupMembersPresenceResponse.java
class GroupMembersPresenceResponse
  - away: List<MemberPresence>
  - groupId: String
  - online: List<MemberPresence>
  class MemberPresence
    - userId: String

### com/groupme/api/presence/UpdatePresenceRequestBody.java
class UpdatePresenceRequestBody
  - manual: Boolean
  - status: String

### com/groupme/api/presence/UserPresenceResponse.java
class UserPresenceResponse
  - last_active: Double
  - sms_enabled: Boolean
  - status: String
  - userId: String

### com/groupme/api/presence/UsersPresenceResponse.java
class UsersPresenceResponse
  - users: List<UserPresence>
  class UserPresence
    - last_active: Long
    - status: String
    - userId: String

### com/groupme/api/campusEventDiscovery/CampusEventCreateTemplateList.java
class CampusEventCreateTemplateList
  - assetId: String
  - description: String
  - glyph: String
  - id: String
  - imageUrl: String
  - title: String
  - widgetName: String

### com/groupme/api/campusEventDiscovery/CampusEventsDirectory.java
class CampusEventsDirectory
  - directory_events: List<CampusEventsInfo>

### com/groupme/api/campusEventDiscovery/CampusEventsInfo.java
class CampusEventsInfo
  - aesthetics: EventAesthetics
  - conversation_id: String
  - directory_id: String
  - end_at_set: Boolean
  - end_time: String
  - going: int
  - going_avatar_urls: ArrayList<String>
  - id: String
  - image_url: String
  - name: String
  - not_going: int
  - start_time: String
  - timezone: String

### com/groupme/api/campusEventDiscovery/CampusEventsResponse.java
class CampusEventsResponse
  - meta: Meta
  - response: CampusEventsDirectory

### com/groupme/api/campusEventDiscovery/Meta.java
class Meta
  - code: int

### com/groupme/model/Favorites.java
class Favorites
  - mHashCode: int
  - mUnorderedUsers: String[]
  - sEmptyUnordered: String[]
  - EMPTY: Favorites

### com/groupme/model/Filter.java
class Filter
  - createdAt: long
  - groupIds: List
  - id: String
  - name: String
  - type: FilterType
  - updatedAt: long
  class Companion
  class FilterType
    - value: String

### com/groupme/model/GroupMeAuthorities.java
class GroupMeAuthorities
  - AUTHORITY: String
  - AUTHORITY_CLEANUP: String
  - AUTHORITY_CONTACTS: String
  - AUTHORITY_CONVERSATIONS: String
  - AUTHORITY_POWERUPS: String
  - AUTHORITY_PROFILE: String
  - AUTHORITY_RELATIONSHIPS: String

### com/groupme/model/LegacyDatabaseHelper.java
class LegacyDatabaseHelper
  - mAccountService: AccountService
  - mCallbacks: Callbacks
  class Callbacks

### com/groupme/model/MediaAttachment.java
class MediaAttachment
  - blurHash: String
  - category: Category
  - duration: int
  - id: String
  - mediaType: int
  - mediaUri: String
  - mediaUrl: String
  - messageId: String
  - partialImageContent: String
  - partialImageId: String
  - previewUrl: String
  - sentState: int
  - sourceGuid: String
  - sourceType: int
  - transcriptUrl: String
  - userId: String
  - videoEndTime: int
  - videoStartTime: int
  - waveform: String
  class Category
    - value: int
    class Companion
  class Companion
  class MediaType
    - value: int
    class Companion
  class SourceType
    - value: int
    class Companion

### com/groupme/model/Member.java
class Member
  - mAppInstalled: boolean
  - mImageUrl: String
  - mIsAutoKicked: boolean
  - mIsBlocked: boolean
  - mMemberId: String
  - mMuted: boolean
  - mMutedUntil: String
  - mName: String
  - mNickName: String
  - mPhoneNumber: String
  - mRole: String
  - mState: String
  - mUserId: String

### com/groupme/model/MemberQuery.java
class MemberQuery
  - PROJECTION: String[]

### com/groupme/model/Message.java
class Message
  - mAutoKickedUserId: String
  - mAvatarUrl: String
  - mConversationId: String
  - mCreatedAtInMs: long
  - mDeletedAtInMs: long
  - mDeletionActor: String
  - mDocument: Document
  - mEditStatus: Status
  - mEvent: Event
  - mEventType: String
  - mFavoritedBy: Favorites
  - mHasCopilotCardAttachment: boolean
  - mHasPsuedoGuid: boolean
  - mId: String
  - mIsPartialImage: boolean
  - mIsSystem: boolean
  - mLocalPhotoUriList: String[]
  - mLocation: Location
  - mMediaAttachmentType: int
  - mMediaAttachments: List
  - mMentions: Mention[]
  - mMultiImage: boolean
  - mOriginalPhotoUrlList: String[]
  - mPendingMentions: Mention[]
  - mPendingText: Text
  - mPhoneNumber: String
  - mPhotoUrlList: String[]
  - mPicture: Picture
  - mPinnedAt: long
  - mPinnedBy: String
  - mPoll: Poll
  - mPromptSender: String
  - mReactions: Map
  - mReply: Reply
  - mSendStatus: Status
  - mSenderId: String
  - mSenderName: String
  - mSenderType: Type
  - mSendingDocumentUri: String
  - mSourceGuid: String
  - mSystemEvent: SystemEvent
  - mText: Text
  - mUndeliverableMemberGuids: String
  - mUpdatedAt: long
  - mUserId: String
  - mVanishingDeliveryId: String
  - mVanishingMediaDeleted: boolean
  - mVanishingReplayAllowed: boolean
  - mVanishingViewedBy: String[]
  - mVideo: Video
  - sGson: Gson
  class Attachment
  class Document
    - EMPTY: Document
    - id: String
    - mIsValid: boolean
  class Event
    - EMPTY: Event
  class JsonItem
    - mIsValid: boolean
    - mItem: Object
    - mJson: String
  class Location
    - EMPTY: Location
    - lat: double
    - lng: double
    - name: String
  class Mention
    - EMPTY_MENTIONS: Mention[]
    - end: int
    - start: int
    - userId: String
  class Picture
    - EMPTY: Picture
    - blurhash: String
    - isGif: boolean
    - sourceUrl: Uri
  class Poll
    - EMPTY: Poll
    - mId: String
    - mIsValid: boolean
  class Reaction
    - reaction: String
    - reaction_type: String
    - reaction_user_ids: ArrayList
  class Reply
    - EMPTY: Reply
    - base_reply_id: String
    - reply_id: String
  class Status
    - mValue: int
  class SystemEvent
    - isProcessed: boolean
  class SystemEventProvider
  class Text
    - emojiCharMap: String
    - emojiPlaceHolder: String
    - isValid: boolean
    - text: String
    - url: Uri
    - URL_PATTERN: Pattern
    - EMPTY: Text
  class Type
    - mValue: String
  class Video
    - EMPTY: Video
    - blurhash: String
    - endTime: int
    - externalURL: String
    - localURL: String
    - previewUrl: Uri
    - startTime: int
  class Viewable
    - height: int
    - isLocal: boolean
    - url: Uri
    - width: int

### com/groupme/model/MessageQuery.java
class MessageQuery
  - PROJECTION: String[]

### com/groupme/model/MessageReactionsQuery.java
class MessageReactionsQuery
  - PROJECTION: String[]

### com/groupme/model/R.java
class R
  class string
    - app_name: int

### com/groupme/model/ServerError.java
class ServerError
  - data: String
  - statusCode: int

### com/groupme/model/findfriends/DmRequest.java
class DmRequest
  - created_at: long
  - last_message: Message
  - messages_count: int
  - other_user: RequestUser
  - requires_approval: boolean
  - unread_count: Integer
  - updated_at: long

### com/groupme/model/findfriends/FindFriendsRequests.java
class FindFriendsRequests
  - counts: RequestCounts
  - dm_requests: List<DmRequest>
  - group_requests_received: List<GroupRequestReceived>
  - group_requests_sent: List<GroupRequestSent>
  class Envelope
    - meta: Meta
    - response: FindFriendsRequests

### com/groupme/model/findfriends/GroupRequestReceived.java
class GroupRequestReceived
  - count: int
  - groupId: String
  - image_url: String
  - name: String

### com/groupme/model/findfriends/GroupRequestSent.java
class GroupRequestSent
  - groupId: String
  - image_url: String
  - name: String
  - state: String
  - updated_at: long
  - user_count: int

### com/groupme/model/findfriends/RequestCounts.java
class RequestCounts
  - dm: int
  - received: int
  - sent: int
  - total: int

### com/groupme/model/findfriends/RequestCountsResponse.java
class RequestCountsResponse
  - counts: RequestCounts
  class Envelope
    - response: RequestCountsResponse

### com/groupme/model/findfriends/RequestUser.java
class RequestUser
  - avatar_url: String
  - id: String
  - name: String

### com/groupme/model/contactranking/BatchWaveResponse.java
class BatchWaveResponse
  - results: List<BatchWaveResult>
  class Envelope
    - meta: Meta
    - response: BatchWaveResponse

### com/groupme/model/contactranking/BatchWaveResult.java
class BatchWaveResult
  - candidate_id: String
  - conversation_id: String
  - error: String
  - messageId: String
  - status: String

### com/groupme/model/contactranking/ContactRankingIntent.java
class ContactRankingIntent
  - value: String

### com/groupme/model/contactranking/ContactSuggestion.java
class ContactSuggestion
  - avatar_url: String
  - candidate_id: String
  - contact_id: String
  - context: String
  - context_type: String
  - email: String
  - is_on_platform: boolean
  - name: String
  - phone: String
  - position: int
  - primary_signal: String
  - userId: String

### com/groupme/model/contactranking/ContactSuggestionsResponse.java
class ContactSuggestionsResponse
  - new_connections: List<ContactSuggestion>
  - new_connections_count: int
  - new_connections_truncated: boolean
  - next_page: String
  - next_page_url: String
  - suggestions: List<ContactSuggestion>
  - weight_version: String
  class Envelope
    - meta: Meta
    - response: ContactSuggestionsResponse

### com/groupme/model/contactranking/ContactSyncRequest.java
class ContactSyncRequest
  - contacts: List<SyncContact>

### com/groupme/model/contactranking/SyncContact.java
class SyncContact
  - contact_id: String
  - email: String
  - has_birthday: boolean
  - has_photo: boolean
  - is_favorite: boolean
  - name: String
  - phone: String

### com/groupme/model/contactranking/SyncContactsResponse.java
class SyncContactsResponse
  - batch_id: String
  - filtered: int
  - normalized: int
  - total: int
  class Envelope
    - meta: Meta
    - response: SyncContactsResponse

### com/groupme/model/contactranking/WaveResponse.java
class WaveResponse
  - conversation_id: String
  - messageId: String
  class Envelope
    - meta: Meta
    - response: WaveResponse

### com/groupme/model/provider/GroupMeContract.java
class GroupMeContract
  - BASE_CONTENT_URI: Uri
  class Album
    - CONTENT_URI: Uri
  class AlbumColumns
  class BaseContract
  class BaseGroupColumns
  class ChatColumns
  class Chats
    - CONTENT_URI: Uri
  class ConversationColumns
  class ConversationLikes
    - CONTENT_URI: Uri
  class Conversations
    - CONTENT_URI: Uri
    - UNREAD_CONTENT_URI: Uri
    - CONTENT_URI_ALL: Uri
    - PINNED_CONVERSATIONS_URI: Uri
    - CONTENT_URI_WITH_TOPICS: Uri
  class DirectoryGroupColumns
  class DirectoryGroups
    - CONTENT_URI: Uri
  class DocumentColumns
  class Documents
    - CONTENT_URI: Uri
  class EventColumns
  class Events
    - CONTENT_URI: Uri
  class Gallery
    - CONTENT_URI: Uri
  class GalleryColumns
  class GroupColumns
  class GroupLikeColumns
  class Groups
    - CONTENT_URI: Uri
  class GroupsToAddTo
    - CONTENT_URI: Uri
  class MediaAttachmentColumns
  class MediaAttachments
    - CONTENT_URI: Uri
    - MEDIA_PROJECTION: String[]
    - ALBUM_PROJECTION: String[]
  class MemberColumns
  class Members
    - CONTENT_URI: Uri
  class MembershipStates
    - CONTENT_URI: Uri
  class MembershipStatesColumns
  class MentionColumns
  class Mentions
    - CONTENT_URI: Uri
  class MessageColumns
  class MessageReactionColumns
  class MessageReactions
    - CONTENT_URI: Uri
  class Messages
    - CONTENT_URI: Uri
  class NotificationMessages
    - CONTENT_URI: Uri
  class NotificationMessagesColumns
  class PollColumns
  class PollOptionColumns
  class PollOptions
    - CONTENT_URI: Uri
  class Polls
    - CONTENT_URI: Uri
  class PowerUpCategories
    - CONTENT_URI: Uri
  class PowerUpCategoryColumns
  class PowerUpColumns
  class PowerUps
    - CONTENT_URI: Uri
  class RankedContactColumns
  class RankedContacts
    - CONTENT_URI: Uri
  class RecentMembers
    - CONTENT_URI: Uri
  class RelationshipColumns
  class Relationships
    - CONTENT_URI: Uri
  class SearchMessageColumns
  class SearchMessages
    - CONTENT_URI: Uri
  class TransferrableGroups
    - CONTENT_URI: Uri
  class UserDirectories
    - CONTENT_URI: Uri
  class UserDirectoriesColumns

### com/groupme/model/provider/GroupMeDatabaseHelper.java
class GroupMeDatabaseHelper
  - mAccountService: AccountService
  - mApplicationService: ApplicationService
  - mNotificationService: NotificationService
  - mPreferenceService: PreferenceService
  class Tables
  class Triggers
  class Views

### com/groupme/model/provider/GroupMeProvider.java
class GroupMeProvider
  - mDatabaseHelper: GroupMeDatabaseHelper
  - mBatchMode: boolean
  - sLock: Object
  - sUriMatcher: UriMatcher
  - sNoViewRegex: Pattern
  - isReadLockEnabled: boolean
  - isPagedMessageQueryEnabled: boolean

### com/groupme/model/provider/PagedMessageQuery.java
class PagedMessageQuery
  - sReactionsViewBody: volatile String

### com/groupme/model/provider/SelectionBuilder.java
class SelectionBuilder
  - mProjectionMap: HashMap
  - mSelection: StringBuilder
  - mSelectionArgs: ArrayList
  - mTable: String

### com/groupme/model/presence/PresenceStatus.java
class PresenceStatus
  - apiValue: String
  - displayNameRes: int
  - manualApiValue: String
  - telemetryValue: String
  class Companion
