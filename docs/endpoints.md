# Endpoint reference

Generated from `Endpoints.java` in the GroupMe Android APK. Every entry lists the HTTP method
(recovered from the Volley request class that builds the URL), the resolved URL, extra query
parameters, and any JSON body keys found in the corresponding `getBody()`.

Placeholder names are inferred from the surrounding path segment; the app itself only has
`str`, `str2` and friends. `{conversationId}` for a DM is the two user ids joined by `+`,
smaller id first (see [conventions](conventions.md)).

## Albums

### `Albums.deleteMediaUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/albums/media/delete
```

Body keys: `media_urls`

Source: `com/groupme/android/album/request/DeleteMediaRequest.java`

### `Albums.detachMediaUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/albums/media/detach
```

Body keys: `album_id`, `media_urls`

Source: `com/groupme/android/album/request/DetachMediaFromAlbumRequest.java`

### `Albums.getAlbumDetails`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/albums/{albumId}
```

Response type: `AlbumDetailsResponse`

### `Albums.getAlbumMedia`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/albums/{albumId}/media
```

Optional query: `per_page`, `page`

Response type: `AlbumMediaResponse`

### `Albums.getAlbumUnfurlUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/album/unfurl
```

Optional query: `album_id`

Response type: `AlbumDetailsResponse`

### `Albums.getAlbumUploadUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/albums/media
```

Optional query: `album_id`

Body keys: `blur_hash`, `media_source`, `media_type`, `media_url`, `preview_url`

Source: `com/groupme/android/album/request/PostAddMediaToAlbumRequest.java`

### `Albums.getConversationAlbumsListUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/albums
```

Optional query: `per_page`, `page`

Response type: `AlbumsResponse`

### `Albums.getCreateAlbumUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/albums/create
```

Body keys: `title`

Response type: `AlbumDetailsResponse`

Source: `com/groupme/android/album/request/PostAlbumCreateRequest.java`

### `Albums.getDeleteAlbumUrl`

```
DELETE https://api.groupme.com/v3/conversations/{conversationId}/albums/{albumId}
```

### `Albums.getUpdateAlbumDetailsUrl`

```
PUT https://api.groupme.com/v3/conversations/{conversationId}/albums/update
```

Optional query: `album_id`

Body keys: `cover_image_url`, `title`

Response type: `AlbumDetailsResponse`

Source: `com/groupme/android/album/request/UpdateAlbumRequest.java`

### `Albums.updateMediaViewCountUrl`

```
PUT https://api.groupme.com/v3/conversations/{conversationId}/albums/media/update?album_id={album_id}
```

Body keys: `media_url`, `views`

Source: `com/groupme/android/album/request/PostAlbumMediaViewCountRequest.java`


## AskCopilotSessions

### `AskCopilotSessions.getCreateSessionUrl`

```
POST https://api.groupme.com/v1/copilot/sessions
```

Body keys: `conversationId`, `sourceMessageAttachments`, `sourceMessageId`, `sourceMessageText`, `timeZone`, `type`, `url`

Response type: `CreateSessionResponse`

Source: `com/groupme/android/copilot/askcopilot/request/CreateCopilotSessionRequest.java`

### `AskCopilotSessions.getDeleteSessionUrl`

```
DELETE https://api.groupme.com/v1/copilot/sessions/{sessionId}
```

### `AskCopilotSessions.getSendMessageUrl`

```
POST https://api.groupme.com/v1/copilot/sessions/{sessionId}/messages
```

Body keys: `attachments`, `text`, `type`, `url`

Response type: `SendMessageResponse`

Source: `com/groupme/android/copilot/askcopilot/request/SendCopilotMessageRequest.java`

### `AskCopilotSessions.getShareUrl`

```
POST https://api.groupme.com/v1/copilot/sessions/{sessionId}/share
```

Body keys: `conversationId`, `copilotMessageId`, `partId`, `text`

Source: `com/groupme/android/copilot/askcopilot/request/ShareRequest.java`

### `AskCopilotSessions.getSubmitFeedbackUrl`

```
POST https://api.groupme.com/v1/copilot/sessions/{sessionId}/feedback
```

Body keys: `messageId`, `partId`, `reaction`

Source: `com/groupme/android/copilot/askcopilot/request/SubmitFeedbackRequest.java`


## Blocks

### `Blocks.getUrl`

```
GET https://api.groupme.com/v3/blocks?user={user}
```

Response type: `Block.BlockIndexResponse`

### `Blocks.postUrl`

```
POST (DELETE to unblock) https://api.groupme.com/v3/blocks?user={user}&otherUser={otherUser}
```


## Calling

### `Calling.callDisconnectUrl`

```
POST https://api.groupme.com/v1/conversations/{conversationId}/call/disconnect
```

Body keys: `meeting_id`, `meeting_type`

Source: `com/groupme/android/calling/request/CallDisconnectRequest.java`

### `Calling.callHeartbeatUrl`

```
PUT https://api.groupme.com/v1/conversations/{conversationId}/call/heartbeat
```

Body keys: `meeting_id`, `meeting_type`

Source: `com/groupme/android/calling/request/CallHeartbeatRequest.java`

### `Calling.callRefreshTokenUrl`

```
POST https://api.groupme.com/v1/conversations/{conversationId}/call/token/refresh
```

Response type: `CallRefreshToken`

### `Calling.dmCallDisconnectUrl`

```
POST https://api.groupme.com/v1/call/disconnect
```

Body keys: `callee_user_id`

Source: `com/groupme/android/calling/request/DMCallDisconnectRequest.java`

### `Calling.getACSIdentityToUserMapUrl`

```
GET https://api.groupme.com/v1/conversations/{conversationId}/identities
```

Response type: `ACSUserMapResponse`

### `Calling.getCallDetailsUrl`

```
GET https://{Id}/conversations/{conversationId}/call
```

Response type: `CallDetails`

### `Calling.getDMCallDetailsUrl`

```
GET https://api.groupme.com/v1/identity/lookup?user_id={user_id}
```

Response type: `DMCallDetails`

### `Calling.getEventCallDetailsUrl`

```
GET https://api.groupme.com/v2/conversations/{conversationId}/call/{callId}/event
```

Response type: `CallDetails`


## Category

### `Category.getGroupsUrl`

```
GET https://api.groupme.com/v3/categories/{categorieId}/groups?page={page}&per_page={per_page}
```

Response type: `DirectoryGroup.GroupEnvelope`


## Chats

### `Chats.deleteUrl`

```
DELETE https://api.groupme.com/v3/chats/{conversationId}
```

### `Chats.getChatUrl`

```
GET https://api.groupme.com/v3/chats/{otherUserId}?include={include}
```

### `Chats.getClearHistoryUrl`

```
POST https://v2.groupme.com/direct_messages/clear_history?other_user_id={other_user_id}
```

### `Chats.getCocoSummarizationUrl`

```
DELETE,GET,POST https://api.groupme.com/v3/messages/{messageId}/draft
```

Body keys: `attachments`, `last_read_message_id`, `message`, `time_zone`, `type`

Response types: `DraftMessageResponse.GetSummaryResponse`, `DraftMessageResponse.Message`

Source: `com/groupme/android/coco/CreateCocoSummaryRequest.java`

### `Chats.getExtendedUrl`

```
GET https://api.groupme.com/v3/chats?page={page}&per_page={per_page}&include=unread_count
GET https://api.groupme.com/v3/chats?page={page}&per_page={per_page}
```

Appended conditionally: `&include=unread_count`

### `Chats.getRandomFilterUrl`

```
POST https://api.groupme.com/v3/big_red_button/{filterName}
```

Body keys: `type`

Source: `com/groupme/android/coco/RandomFilterRequest.java`

### `Chats.getRequestApprovalUrl`

```
POST https://api.groupme.com/v3/chats/{conversationId}/approve
```

### `Chats.getUpdateChatThemeUrl`

```
PUT https://api.groupme.com/v3/conversations/{conversationId}/theme
```

### `Chats.getUrl`

```
GET https://api.groupme.com/v3/chats?page={page}&per_page={per_page}&include=unread_count
GET https://api.groupme.com/v3/chats?page={page}&per_page={per_page}
```

Appended conditionally: `&include=unread_count`

### `Chats.postReadReceipt`

```
POST https://v2.groupme.com/read_receipts
```

Body keys: `chat_id`, `read_receipt`

Source: `com/groupme/android/chat/ReadReceiptRequest.java`


## Contacts

### `Contacts.getBatchWaveUrl`

```
POST https://api.groupme.com/v4/contacts/waves/batch
```

Response types: `BatchWaveResponse`, `BatchWaveResponse.Envelope`

Source: `com/groupme/android/contactranking/requests/BatchWaveContactsRequest.java`

### `Contacts.getDismissUrl`

```
POST https://api.groupme.com/v4/contacts/suggestions/{suggestionId}/dismiss
```

Source: `com/groupme/android/contactranking/requests/DismissSuggestionRequest.java`

### `Contacts.getImpressionUrl`

```
POST https://api.groupme.com/v4/contacts/suggestions/{suggestionId}/impression
```

Source: `com/groupme/android/contactranking/requests/RecordImpressionRequest.java`

### `Contacts.getSuggestionsUrl`

```
GET https://api.groupme.com/v4/contacts/suggestions
```

Optional query: `intent`, `limit`, `cursor`, `group_id`

Response types: `ContactSuggestionsResponse`, `ContactSuggestionsResponse.Envelope`

### `Contacts.getSyncUrl`

```
DELETE,POST https://api.groupme.com/v4/contacts/sync
```

Response types: `SyncContactsResponse`, `SyncContactsResponse.Envelope`

Source: `com/groupme/android/contactranking/requests/SyncContactsRequest.java`

### `Contacts.getWaveUrl`

```
POST https://api.groupme.com/v4/contacts/suggestions/{suggestionId}/wave
```

Response types: `WaveResponse`, `WaveResponse.Envelope`

Source: `com/groupme/android/contactranking/requests/WaveContactRequest.java`


## Copilot

### `Copilot.getCopilotSelectionStyleImagesUrl`

```
GET https://cdn.groupme.com/assets/image-remix/{styleName}.jpg?version={version}
```

### `Copilot.getCopilotSelectionStylesUrl`

```
GET https://cdn.groupme.com/assets/image-remix/image-remix.{lang}.json?version={version}
```

### `Copilot.getPromptSuggestionsUrl`

```
GET https://cdn.groupme.com/assets/copilot-hints/copilot-hints.{lang}.json?version={version}
```


## CopilotStudySets

### `CopilotStudySets.getCardImpressionUrl`

```
POST https://api.groupme.com/v1/copilot/card-impression
```

Body keys: `cardId`, `cardType`, `conversationId`, `messageId`

Source: `com/groupme/android/copilot/cards/AnswerCardImpressionRequest.java`

### `CopilotStudySets.getLeaderboardUrl`

```
GET https://api.groupme.com/v1/copilot/study-sets/{studySetId}/leaderboard
```

Optional query: `groupId`, `recipientId`

Response types: `LeaderboardResponse`, `LeaderboardResponseEnvelope`

### `CopilotStudySets.getScoreUrl`

```
POST https://api.groupme.com/v1/copilot/study-sets/{studySetId}/score
```

Body keys: `cardType`, `correct`, `groupId`, `messageId`, `recipientId`, `score`, `title`, `total`

Response types: `ScoreResponse`, `ScoreResponseEnvelope`

Source: `com/groupme/android/copilot/cards/leaderboard/ScoreReportRequest.java`


## CuratedMedia

### `CuratedMedia.getCuratedMediaUrl`

```
GET https://api.groupme.com/v1/curated-media
```

Response type: `CuratedMedia`


## DeviceVerification

### `DeviceVerification.getNonceUrl`

```
GET https://api.groupme.com/v1/nonce
```

Response type: `NonceResponse`


## Directory

### `Directory.getBlendedSearchUrl`

```
GET https://api.groupme.com/v1/search/directory
```

Response types: `SearchCampusResponse`, `SearchCampusResponseEnvelope`

### `Directory.getCreateVerificationUrl`

```
POST https://api.groupme.com/v3/directories/{directoryId}/verifications 
```

Body keys: `school_email`

Response type: `NetworkResponse`

Source: `com/groupme/android/group/directory/requests/CreateVerificationRequest.java`

### `Directory.getDirectoryDataUrl`

```
GET https://api.groupme.com/v3/directories/{directoryId}
```

Response types: `DirectoryDetailsResponse`, `DirectoryDetailsResponse.DirectoryDetails`

### `Directory.getDirectoryMemberProfileUpdateUrl`

```
PUT https://api.groupme.com/v3/directories/user/membership
```

Body keys: `campus_profile_visibility`, `graduation_year`

Response type: `DirectoryMemberProfileResponse`

Source: `com/groupme/android/group/directory/requests/DirectoryMemberProfileUpdateRequest.java`

### `Directory.getGroupsUrl`

```
GET https://api.groupme.com/v3/directories/{directoryId}/groups?page={page}&per_page={per_page}
```

Response type: `DirectoryGroup.GroupEnvelope`

### `Directory.getMajorListUrl`

```
GET https://cdn.groupme.com/assets/majors/majors.{lang}.json?version={version}
```

### `Directory.getNearbyDirectoriesUrl`

```
GET https://api.groupme.com/v1/search/directories/nearby
```

Optional query: `latitude`, `longitude`, `query`, `per_page`, `from`, `country`, `sort`

Response type: `Directory.NearbyDirectoriesEnvelope`

### `Directory.getPreviewUrl`

```
GET https://api.groupme.com/v3/directories/{directoryId}/preview/{shareToken}
```

Response types: `Directory`, `Directory.DirectoryPreviewEnvelope`

### `Directory.getRecommendUrl`

```
GET https://api.groupme.com/v3/directories/recommend
```

Response types: `Directory`, `Directory.DirectoryPreviewEnvelope`

### `Directory.getSaveUserMajorUrl`

```
PUT https://api.groupme.com/v3/directories/user/majors
```

Body keys: `codes`

Source: `com/groupme/android/group/directory/requests/SaveUserMajorsRequest.java`

### `Directory.getSearchDirectoriesUrl`

```
POST https://api.groupme.com/v3/directories/search
```

Body keys: `school_email`

Response types: `Directory`, `Directory.DirectoryEnvelope`

Source: `com/groupme/android/group/directory/requests/EmailToDirectoryRequest.java`

### `Directory.getUserDirectoriesUrl`

```
GET https://api.groupme.com/v3/directories
```

Response type: `Directory.UserDirectoriesEnvelope`

### `Directory.getVerificationUrl`

```
PUT https://api.groupme.com/v3/directories/verifications/{verificationId}?swap={swap}
```

Response type: `Directory.UserDirectoriesEnvelope`

### `Directory.leaveDirectoryUrl`

```
DELETE https://api.groupme.com/v3/directories/{directoryId}/membership
```


## Documents

### `Documents.getDocumentMetadataUrl`

```
GET https://file.groupme.com/v1/{conversationId}/fileData/{fileId}
```

Response type: `Document.SingleResponse`

### `Documents.getDocumentUploadUrl`

```
POST (files) / GET (uploadStatus) https://file.groupme.com/v1/{conversationId}/{files|uploadStatus}
```

Response types: `DocumentUploadResponse`, `DocumentUploadStatusResponse`

### `Documents.getDownloadUrl`

```
GET https://file.groupme.com/v1/{conversationId}/files/{fileId}
```

Response type: `Document`


## Events

### `Events.createUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/events/create
```

Response type: `Event.SingleResponse`

Source: `com/groupme/android/event/request/EventCreateRequest.java`

### `Events.deleteRsvpUrl`

```
DELETE https://api.groupme.com/v3/conversations/{conversationId}/events/rsvp/delete?event_id={event_id}
```

Response types: `Event`, `Event.SingleResponse`

### `Events.deleteUrl`

```
DELETE https://api.groupme.com/v3/conversations/{conversationId}/events/delete?event_id={event_id}
```

Optional query: `delete_series`, `delete_future`

### `Events.getEventBannerListUrl`

```
GET https://cdn.groupme.com/assets/event-banners.json
```

### `Events.getEventCreateTemplateListUrl`

```
GET https://cdn.groupme.com/assets/event-templates/event-templates.{lang}.json?version={version}
```

### `Events.getPreviewUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/{eventId}/preview/{shareToken}
```

Response type: `EventPreview`

### `Events.joinEventAndGroupUrl`

```
POST https://api.groupme.com/v3/groups/join_request/{conversationId}/{eventId}/{userId}
POST https://api.groupme.com/v3/groups/join_request/{conversationId}/{eventId}/{userId}?topic_id={topicId}
```

Body keys: `answer`, `response`

Response type: `EventNonMembers`

Source: `com/groupme/android/event/request/PostEventAndGroupJoinRequest.java`

### `Events.listUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/events/list?limit=100
```

Optional query: `last_event_id`, `end_at`

### `Events.rsvpPutUrl`

```
PUT https://api.groupme.com/v4/conversations/{conversationId}/events/{eventId}/rsvp
```

Response types: `Event`, `Event.SingleResponse`

### `Events.rsvpV3Url`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/events/rsvp?event_id={event_id}&going={going}
```

Response types: `Event`, `Event.SingleResponse`

### `Events.seriesInfoUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/events/series?series_id={series_id}
```

Response types: `SeriesInfo`, `SeriesInfo.Response`

### `Events.showUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/events/show?event_id={event_id}
```

Response types: `Event`, `Event.SingleResponse`

### `Events.showUrlForNonMembers`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/events/show?event_id={event_id}&membership_state=true
```

Response type: `EventNonMembers`

### `Events.updateUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/events/update?event_id={event_id}
```

Response type: `Event.SingleResponse`

### `Events.userCalendarUrl`

```
GET https://api.groupme.com/v4/user/events?start_date={start_date}&end_date={end_date}&limit={limit}
```

Optional query: `cursor`

Response type: `UserCalendarEventsResponse`


## Feedback

### `Feedback.getFeedbackUrl`

```
GET https://go.skype.com/{groupme_nps|groupme}?p=GroupMe.Android&v={v}&theme={theme}&e={e}
```

Optional query: `tcg`


## Gallery

### `Gallery.getBeforeUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/gallery
```

Optional query: `before`

### `Gallery.getSinceUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/gallery
```

Optional query: `since`

### `Gallery.getUrl`

```
GET https://api.groupme.com/v3/conversations/{conversationId}/gallery
```


## Groups

### `Groups.buildMuteAllUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/memberships/{mute_all|unmute_all}
```

Body keys: `duration`, `recap_enabled`

Source: `com/groupme/android/group/MuteGroupRequest.java`

### `Groups.buildMuteGroupUrl`

```
POST https://v2.groupme.com/groups/{groupId}/memberships/{mute|unmute}
```

Body keys: `duration`, `recap_enabled`

Source: `com/groupme/android/group/MuteGroupRequest.java`

### `Groups.buildMuteTopicUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/subgroups/{topicId}/{mute|unmute}
```

Body keys: `duration`, `recap_enabled`

Source: `com/groupme/android/group/MuteGroupRequest.java`

### `Groups.createGroupTopicUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/subgroups
```

Body keys: `avatar_url`, `description`, `group_type`, `topic`

Response types: `Topic`, `Topic.TopicCreateResponse`

Source: `com/groupme/android/group/CreateTopicRequest.java`

### `Groups.getCampusEventsSearchUrl`

```
GET https://api.groupme.com/v1/search/directories_events?
```

Optional query: `query`, `from`, `per_page`, `latitude`, `longitude`

Response type: `CampusEventsResponse`

### `Groups.getChangeOwnerUrl`

```
POST https://api.groupme.com/v3/groups/change_owners
```

Body keys: `owner_id`, `requests`

Response types: `ChangeOwnerResponse`, `Group.ChangeOwnerResponse`

Source: `com/groupme/android/group/ChangeOwnerRequest.java`

### `Groups.getChatThemeBannerUrl`

```
GET https://cdn.groupme.com/assets/chat-themes.json
```

Response type: `ThemesResponse`

### `Groups.getClearHistoryUrl`

```
POST https://v2.groupme.com/groups/{groupId}/clear_history
```

### `Groups.getDeleteGroupLocationUrl`

```
DELETE https://api.groupme.com/v3/groups/{groupId}/locations/{locationId}
```

### `Groups.getDestroyUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/destroy
```

### `Groups.getDirectorySearchUrl`

```
GET https://api.groupme.com/v1/search/directories?from={from}&per_page={per_page}
GET https://api.groupme.com/v1/search/directories?query={query}&from={from}&per_page={per_page}
```

Response types: `Group.SearchGroupsResponse`, `Group.SearchGroupsResponse.Response`

### `Groups.getDiscoverGroupPreviewUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/preview
```

Response type: `Group.GroupPreviewResponse`

### `Groups.getDiscoverSearchFetchUrl`

```
GET https://api.groupme.com/v1/search?latitude={latitude}&longitude={longitude}&per_page={per_page}
GET https://api.groupme.com/v1/search?per_page={per_page}
```

Response type: `Group.SearchGroupsResponse`

### `Groups.getDiscoverSearchUrl`

```
GET https://api.groupme.com/v1/search?query={query}&from={from}&latitude={latitude}&longitude={longitude}&per_page={per_page}
GET https://api.groupme.com/v1/search?query={query}&from={from}&per_page={per_page}
```

Response type: `Group.SearchGroupsResponse`

### `Groups.getEventEffectsUrl`

```
GET https://cdn.groupme.com/assets/event-effects.json
```

### `Groups.getEventThemesUrl`

```
GET https://cdn.groupme.com/assets/event-themes.json
```

### `Groups.getExtendedUrlWithoutMembers`

```
GET https://api.groupme.com/v3/groups?page={page}&per_page={per_page}&omit=memberships&include=visibility&include=locations
```

### `Groups.getFormerGroupsUrl`

```
GET https://api.groupme.com/v3/groups/former
```

Optional query: `include_all`

Response type: `Group.IndexResponse`

### `Groups.getGroupAvatarListUrl`

```
GET https://cdn.groupme.com/assets/avatar/group/avatar.json
```

### `Groups.getGroupLocationsUrl`

```
GET,POST https://api.groupme.com/v3/groups/{groupId}/locations
```

Response type: `Location.GetGroupLocationsResponse`

### `Groups.getGroupTopicsBatchUrl`

```
GET https://api.groupme.com/v3/groups/{groupId,groupId,...}/subgroups?include=unread_count
GET https://api.groupme.com/v3/groups/{groupId,groupId,...}/subgroups
```

Appended conditionally: `?include=unread_count`

Response type: `Topic.TopicIndexResponse`

### `Groups.getGroupTopicsUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/subgroups?include=unread_count
GET https://api.groupme.com/v3/groups/{groupId}/subgroups
```

Appended conditionally: `?include=unread_count`

Response type: `Topic.TopicIndexResponse`

### `Groups.getHideFormerGroupUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/memberships/hide_former
```

Response type: `HideFormerGroupResponse`

### `Groups.getInactiveMembersUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/members?filter=inactive
```

Response type: `Member.FormerMembersResult`

### `Groups.getIndexUrl`

```
POST https://api.groupme.com/v3/groups
```

Body keys: `chaos`, `description`, `directory_id`, `event_details`, `expires_in_hours`, `image_url`, `name`, `type`

Response types: `Group`, `Group.SingleResponse`

Source: `com/groupme/android/group/StartGroupRequest.java`

### `Groups.getNearbySearchUrl`

```
GET https://api.groupme.com/v1/search/nearby?from={from}&latitude={latitude}&longitude={longitude}&per_page={per_page}
GET https://api.groupme.com/v1/search/nearby?query={query}&from={from}&latitude={latitude}&longitude={longitude}&per_page={per_page}
```

Response type: `Group.SearchGroupsResponse`

### `Groups.getPendingRequestsUrl`

```
GET https://api.groupme.com/v3/groups/pending_memberships
```

Response type: `PendingRequestSummaryResponse`

### `Groups.getPinnedConversationsUrl`

```
GET,PUT https://api.groupme.com/v4/pinned_conversations
```

Body keys: `pinned_conversation_ids`

Response types: `PinnedConversationsResponse`, `PinnedConversationsResponse.Response`

Source: `com/groupme/android/conversation/GetPinnedConversationsRequest.java`

### `Groups.getPopularSearchUrl`

```
GET https://api.groupme.com/v1/search/popular?from={from}&per_page={per_page}
GET https://api.groupme.com/v1/search/popular?query={query}&from={from}&per_page={per_page}
```

Response type: `Group.SearchGroupsResponse`

### `Groups.getSuggestionsUrl`

```
POST https://api.groupme.com/v3/groups/suggestions
```

Response type: `SuggestedGroup.IndexResponse`

### `Groups.getTopicUrl`

```
DELETE,GET https://api.groupme.com/v3/groups/{groupId}/subgroups/{topicId}?include={include}
```

Response types: `T`, `Topic.TopicGetResponse`

### `Groups.getTrendingSearchUrl`

```
GET https://api.groupme.com/v1/search/trending?from={from}&per_page={per_page}
GET https://api.groupme.com/v1/search/trending?query={query}&from={from}&per_page={per_page}
```

Response types: `Group.SearchGroupsResponse`, `Group.SearchGroupsResponse.Response`

### `Groups.getUpdateGroupUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/update
```

Response types: `Group.SingleResponse`, `T`

### `Groups.getUpdateRoleUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/members/{memberId}/update
```

Body keys: `role`

Response types: `Group.UpdateRollResponse`, `UpdateRollResponse`

Source: `com/groupme/android/group/UpdateRollRequest.java`

### `Groups.getUpdateSystemMessageSettingsUrl`

```
PUT https://api.groupme.com/v3/groups/{groupId}/settings
```

Body keys: `all_notifications`, `categories`, `system_message_settings`

Response types: `Group.SingleResponse`, `SystemMessageSettings`

Source: `com/groupme/android/group/UpdateSystemMessageSettingsRequest.java`

### `Groups.getUpdateTopicUrl`

```
PUT https://api.groupme.com/v3/groups/{groupId}/subgroups/{topicId}
```

### `Groups.getUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}?include={include}
```

Response types: `Group`, `Group.SingleResponse`

### `Groups.getUrlWithoutMembers`

```
GET https://api.groupme.com/v3/groups?page={page}&per_page={per_page}&omit=memberships&include=unread_count
GET https://api.groupme.com/v3/groups?page={page}&per_page={per_page}&omit=memberships
```

Appended conditionally: `&include=unread_count`

### `Groups.joinGroupPreviewUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/preview/{shareToken}
```

Response types: `Group`, `Group.JoinGroupPreviewResponse`

### `Groups.joinGroupUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/join
```

Body keys: `answer`, `directory_id`, `response`, `share_token`

Response types: `Group.JoinGroupResponse`, `JoinGroupResult`

Source: `com/groupme/android/group/JoinGroupRequest.java`

### `Groups.postRejoinGroupUrl`

```
POST https://v2.groupme.com/groups/{groupId}/memberships/activate
```

Response type: `Group`

### `Groups.postSealMembershipUrl`

```
POST https://v2.groupme.com/groups/{groupId}/memberships/{membershipId}/destroy?force=true
```

### `Groups.postUnsealMembershipUrl`

```
POST https://v2.groupme.com/groups/{groupId}/memberships/{membershipId}/activate
```


## InlineDownloader

### `InlineDownloader.getIFramelyPreviewUrl`

```
GET https://api.groupme.com/v1/urls/preview?url={url}&theme=dark&_theme=dark
GET https://api.groupme.com/v1/urls/preview?url={url}
```

Appended conditionally: `&theme=dark&_theme=dark`

Response type: `InlineContentModel`


## Installations

### `Installations.postIntallationUrl`

```
POST https://api.groupme.com/v3/installations
```

Body keys: `app_version`, `client_id`, `country`, `installation`, `language`, `manufacturer`, `os_version`, `platform`

Source: `com/groupme/android/login/InstallationRequest.java`


## Invites

### `Invites.getClaimUrl`

```
POST https://v2.groupme.com/invites/{inviteToken}/claim
```

Response type: `Group`

### `Invites.getUrl`

```
GET https://v2.groupme.com/invites/{inviteToken}
```

Response types: `Group`, `Group.JoinGroupResponse`


## Location

### `Location.getLocationSearchUrl`

```
GET https://api.groupme.com/v1/location/locations?query={query}
```

Response type: `Location.SearchLocationResponse`

### `Location.getNearbyLocationsUrl`

```
GET https://api.groupme.com/v1/location/nearby?latitude={latitude}&longitude={longitude}
```

Response types: `Location.SearchLocationResponse`, `Venue.VenuesResponse`


## Matchups

### `Matchups.getGroupSportsEventUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/sports_events
```

Response types: `ParsedSportsEvents`, `SportsEventEnvelope`

### `Matchups.getMatchupsUrl`

```
GET https://api.groupme.com/v1/matchups
```

Response type: `Matchup.MatchupsEnvelope`

### `Matchups.getMatchupsUrlV2`

```
GET https://api.groupme.com/v2/matchups
```

Response type: `FootballMatchupsEnvelope`

### `Matchups.getSetSportsTeamUrl`

```
PUT https://api.groupme.com/v3/groups/{groupId}/sports_team
```

Body keys: `team`

Source: `com/groupme/android/group/directory/sports/soccer/SetSportsChatTeamRequest.java`


## MediaUploads

### `MediaUploads.getMediaUploadUrl`

```
POST https://m.groupme.com/uploads
```

Body keys: `fileSize`, `groupId`, `senderId`

Response type: `UploadUrlsModel`

Source: `com/groupme/android/media/MediaUploadUrlRequest.java`


## Members

### `Members.approvePendingMembers`

```
POST https://api.groupme.com/v3/groups/{groupId}/members/approvals
```

Body keys: `approval`, `membership_ids`

Response type: `ProcessPendingMembersResponse`

Source: `com/groupme/android/group/join_requests/ProcessPendingMembersRequest.java`

### `Members.getAddMemberResults`

```
GET https://api.groupme.com/v4/groups/{groupId}/members/results/{resultId}
```

Response types: `AddMemberResult`, `Member.AddMemberResults`

### `Members.getApproveMembershipRequestUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/members/{memberId}/approval
```

Body keys: `approval`

Source: `com/groupme/android/group/join_requests/PendingMembershipApprovalRequest.java`

### `Members.getDestroyUrl`

```
POST https://v2.groupme.com/groups/{groupId}/memberships/{membershipId}/destroy
```

### `Members.getPendingApprovalRequestStatus`

```
GET https://api.groupme.com/v3/groups/{groupId}/members/approvals/{memberId}
```

Response types: `ProcessPendingMembersResponse`, `StatusResponse`

### `Members.getPendingMembershipsUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/pending_memberships
```

Response type: `JoinRequest.JoinRequestList`

### `Members.getUpdateMemberInfoUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/memberships/update
```

Body keys: `avatar_url`, `membership`, `nickname`

Response type: `Member.UpdateMemberResponse`

Source: `com/groupme/android/group/UpdateMemberInfoRequest.java`

### `Members.postAddMembers`

```
POST https://api.groupme.com/v3/groups/{groupId}/members/add
```

Body keys: `members`

Response type: `AddMemberResult`

Source: `com/groupme/android/group/member/AddMemberRequest.java`

### `Members.postRemoveMember`

```
POST https://api.groupme.com/v3/groups/{groupId}/members/{memberId}/remove
```

### `Members.revokePendingRequestUrl`

```
DELETE https://api.groupme.com/v3/groups/{groupId}/revoke_join
```


## Messages

### `Messages.deleteUrl`

```
DELETE https://api.groupme.com/v3/conversations/{conversationId}/messages/{messageId}
```

### `Messages.getHubbleAnimatedReactionUrl`

```
GET https://cdn.hubblecontent.osi.office.net/emojis/publish/{publishId}/png/thumbnails/{thumbnailId}/anim/s1.png
```

### `Messages.getHubbleStaticEmojiUrl`

```
GET https://cdn.hubblecontent.osi.office.net/emojis/publish/{publishId}/png/thumbnails/{thumbnailId}/s1.png
```

### `Messages.getMessageUrl`

```
GET https://api.groupme.com/v4/groups/{groupId}/messages/{messageId}
GET https://api.groupme.com/v3/direct_messages/{messageId}?other_user_id={other_user_id}
```

Optional query: `profile`

Response types: `Message`, `Message.SingleMessageResponse`

### `Messages.getReactionsListUrl`

```
GET https://cdn.groupme.com/assets/reactions.json?version={version}
```

### `Messages.getUrl`

```
GET https://api.groupme.com/v3/groups/{groupId}/messages
GET https://api.groupme.com/v3/direct_messages?other_user_id={other_user_id}
```

Optional query: `limit`, `acceptFiles`, `before_id`, `include`, `profile`

### `Messages.getV4ReadReceipts`

```
GET https://api.groupme.com/v4/read_receipts
```

Response type: `ReadReceiptsResponse`

### `Messages.postBatchReadReceipts`

```
POST https://api.groupme.com/v4/read_receipts
```

Response type: `BatchReadReceiptResponse`

Source: `com/groupme/android/unreadsync/BatchReadReceiptPostRequest.java`

### `Messages.postFavoritesUrl`

```
POST https://api.groupme.com/v3/messages/{conversationId}/{messageId}/{like|unlike}
```

Body keys: `like_icon`, `pack_id`, `pack_index`, `type`

Source: `com/groupme/android/message/ReactionRequest.java`

### `Messages.postMarkAllReadV4`

```
POST https://api.groupme.com/v4/conversations/mark_all_read
```

### `Messages.postUrl`

```
POST https://api.groupme.com/v3/groups/{groupId}/messages
POST https://api.groupme.com/v3/direct_messages
```

Body keys: `attachments`, `card_id`, `card_type`, `direct_message`, `fileSize`, `message`, `mimeType`, `payload`, `recipient_id`, `source_guid`, `source_score`, `source_user_id`, `source_user_name`, `state`, `text`, `title`, `type`

Response type: `Message.SendMessageResponse`

Source: `com/groupme/android/copilot/cards/share/ShareCardRequest.java`

### `Messages.postV4ReadReceipt`

```
POST https://api.groupme.com/v4/read_receipts/{conversationId}
```

Body keys: `last_read_message_id`

Response types: `ReadReceiptResponse`, `ReadReceiptResponse.Response`

Source: `com/groupme/android/unreadsync/UpdateReadCursorRequest.java`

### `Messages.putUrl`

```
PUT https://api.groupme.com/v4/groups/{groupId}/messages/{messageId}
PUT https://api.groupme.com/v4/direct_messages/{messageId}/messages/{messageId}
```

Response type: `Message.SingleMessageResponse`

Source: `com/groupme/android/message/EditMessageRequest.java`


## PinnedMessages

### `PinnedMessages.pinUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/messages/{messageId}/pin
```

### `PinnedMessages.pinnedListDMUrl`

```
GET https://api.groupme.com/v3/pinned/direct_messages?other_user_id={other_user_id}
```

### `PinnedMessages.pinnedListGroupUrl`

```
GET https://api.groupme.com/v3/pinned/groups/{groupId}/messages
```

### `PinnedMessages.unpinUrl`

```
POST https://api.groupme.com/v3/conversations/{conversationId}/messages/{messageId}/unpin
```


## Polls

### `Polls.castMultiVoteUrl`

```
POST https://api.groupme.com/v3/poll/{groupId}/{pollId}
```

Response types: `Poll`, `Poll.CastVoteResponse`

### `Polls.castVoteUrl`

```
POST https://api.groupme.com/v3/poll/{groupId}/{pollId}/{optionId}
```

Response types: `Poll`, `Poll.CastVoteResponse`

### `Polls.createUrl`

```
POST https://api.groupme.com/v3/poll/{groupId}
```

Response type: `Poll.CreatePollResponse`

Source: `com/groupme/android/chat/poll/CreatePollRequest.java`

### `Polls.endUrl`

```
POST https://api.groupme.com/v3/poll/{groupId}/{pollId}/end
```

Response types: `Poll`, `Poll.EndPollResponse`

### `Polls.getAllUrl`

```
GET https://api.groupme.com/v3/poll/{groupId}
GET https://api.groupme.com/v3/poll/{groupId}?continuation_token={continuation_token}
```

Response type: `Poll.GetAllPollsResponse`

### `Polls.getUrl`

```
GET https://api.groupme.com/v3/poll/{groupId}/{pollId}
```

Response types: `Poll`, `Poll.RefreshPollResponse`


## Popular

### `Popular.getDMMyLikes`

```
GET https://api.groupme.com/v4/likes/direct_messages/mine?other_user_id={other_user_id}
```

### `Popular.getDMUserLikes`

```
GET https://api.groupme.com/v4//likes/direct_messages/for_me?other_user_id={other_user_id}
```

### `Popular.getEveryoneLikes`

```
GET https://api.groupme.com/v3/groups/{groupId}/likes?period={period}
```

### `Popular.getGroupMyLikes`

```
GET https://api.groupme.com/v3/groups/{groupId}/likes/mine
```

### `Popular.getGroupUserLikes`

```
GET https://api.groupme.com/v3/groups/{groupId}/likes/for_me
```


## PowerUps

### `PowerUps.getEmojiOutlineUrl`

```
GET https://s3.amazonaws.com/powerups/emoji/{packId}/outline/{density}/{emojiId}.png
```

### `PowerUps.getEmojiStickerUrl`

```
GET https://s3.amazonaws.com/powerups/emoji/{packId}/sticker/{density}/{emojiId}.png
```

Response type: `EmojiMeta`

### `PowerUps.getPurchasesUrl`

```
GET https://powerup.groupme.com/purchases
```

Response types: `PowerUp.PowerUpPurchasesResponse`, `PowerUp.PowerUpResponse`, `PowerUpMeta`

### `PowerUps.getUrl`

```
GET https://powerup.groupme.com/powerups
```

Response types: `PowerUp.PowerUpPurchasesResponse`, `PowerUp.PowerUpResponse`, `PowerUpMeta`


## Presence

### `Presence.getGroupMembersPresence`

```
GET https://api.groupme.com/v1/presence/groups/{groupId}/members
```

Response type: `GroupMembersPresenceResponse`

### `Presence.getUserPresence`

```
GET https://api.groupme.com/v1/presence/users/{userId}
```

Optional query: `directory_id`, `group_id`

Response type: `UserPresenceResponse`

### `Presence.getUsersPresence`

```
GET https://api.groupme.com/v1/presence/users
```

Optional query: `ids`

Response type: `UsersPresenceResponse`

### `Presence.updateUserPresence`

```
PUT https://api.groupme.com/v1/presence/status
```

Source: `com/groupme/android/net/presence/UpdateUserPresenceRequest.java`


## Push

### `Push.getDestroyUrl`

```
POST https://v2.groupme.com/push_registrations/destroy
```

Body keys: `registration_id`

Source: `com/groupme/android/push/UnregisterGroupmePushRequest.java`

### `Push.getRegistrationUrl`

```
POST https://v2.groupme.com/push_registrations
```

Response type: `PushRegistration.Response`


## Recaps

### `Recaps.getLatestRecapUrl`

```
GET https://api.groupme.com/v3/recaps/{conversationId}/latest
```

Response types: `RecapPayload`, `RecapPayload.Recap`

### `Recaps.getRecapsBase`

```
n/a (base URL) https://api.groupme.com/v3/recaps
```

### `Recaps.getTriggerUrl`

```
POST https://api.groupme.com/v3/recaps/schedule
```

Body keys: `last_read_message_id`

Response type: `RecapTriggerResponse`

Source: `com/groupme/android/recap/request/TriggerRecapRequest.java`


## Registration

### `Registration.buildAccountRecoveryUrl`

```
POST https://v2.groupme.com/registrations/change_number
```

Body keys: `app_id`, `device_id`, `phone_number`

Response types: `AccountRecoveryEnvelope`, `AccountRecoveryEnvelope.Response`, `LoginResponse`

Source: `com/groupme/android/welcome/create_account/RecoverAccountRequest.java`

### `Registration.buildAgeVerifyUrl`

```
POST https://api.groupme.com/v3/registrations/age/verify
```

Body keys: `date_of_birth`

Response type: `AgeVerifyEnvelope`

Source: `com/groupme/android/registration/api/AgeVerifyRequest.java`

### `Registration.buildConfirmNewRegistrationUrl`

```
POST https://v2.groupme.com/registrations/{pin}/{longPin}/confirm_new
```

Response types: `Profile.LegacyResponse`, `Profile.LegacyResponse.Response`

### `Registration.buildConfirmPinUrl`

```
POST https://v2.groupme.com/registrations/{pin}/{longPin}/confirm
```

Body keys: `pin`, `registration`

Response types: `Profile.LegacyResponse`, `Profile.LegacyResponse.Response`

Source: `com/groupme/android/welcome/ConfirmPinRequest.java`

### `Registration.buildCreateUrl`

```
POST https://v2.groupme.com/registrations/email_create
```

Body keys: `platform`, `registration`

Response types: `Registration`, `Registration.Response`

Source: `com/groupme/android/welcome/CreateEmailRegistrationRequest.java`

### `Registration.buildEmailValidateUrl`

```
POST https://api.groupme.com/v4/emails/validate
```

Body keys: `verification_token`

Response type: `EmailValidateEnvelope`

Source: `com/groupme/android/registration/api/EmailValidateRequest.java`

### `Registration.buildFacebookCreateUrl`

```
POST https://v2.groupme.com/registrations/facebook_create
```

Body keys: `app_version`, `device_id`, `facebook_access_token`, `platform`, `registration`, `verification`

Source: `com/groupme/android/welcome/facebook/FacebookCreateRequest.java`

### `Registration.buildGoogleCreateUrl`

```
POST https://v2.groupme.com/registrations/google_plus
```

Body keys: `app_version`, `auth_token`, `device_id`, `platform`, `registration`, `verification`

Source: `com/groupme/android/welcome/google/GoogleCreateRequest.java`

### `Registration.buildGoogleCreateV3Url`

```
POST https://api.groupme.com/v3/registrations/google
```

Body keys: `age_token`, `app_version`, `device_id`, `google_access_token`, `nonce`, `platform`, `registration`, `verification`

Response types: `GoogleV3Response`, `MfaChannelEnvelope`

Source: `com/groupme/android/welcome/google/GoogleCreateV3Request.java`

### `Registration.buildMicrosoftCreateUrl`

```
POST https://v2.groupme.com/registrations/microsoft_sso
```

Response types: `MfaChannelEnvelope`, `MicrosoftResponse`

### `Registration.buildMicrosoftCreateV3Url`

```
POST https://api.groupme.com/v3/registrations/microsoft
```

Response types: `MfaChannelEnvelope`, `MicrosoftResponse`

### `Registration.buildMtVerificationUrl`

```
POST https://v2.groupme.com/registrations/{pin}/{longPin}/send_pin
```

Body keys: `client_id`, `phone_number`, `registration`

Response types: `Registration`, `Registration.Response`

Source: `com/groupme/android/welcome/SendPinRequest.java`

### `Registration.buildPasswordResetUrl`

```
POST https://v2.groupme.com/email_password_resets
```

Body keys: `phone_number`

Response types: `PasswordResetResponse`, `Result`

Source: `com/groupme/android/welcome/PasswordResetRequest.java`

### `Registration.buildPhoneVerifyUrl`

```
POST https://api.groupme.com/v3/registrations/phone/verify
```

Body keys: `age_token`, `client_id`, `force_create`, `phone_number`

Response type: `PhoneVerifyEnvelope`

Source: `com/groupme/android/registration/api/PhoneVerifyRequest.java`

### `Registration.buildUpdateUrl`

```
POST https://v2.groupme.com/v2/registrations/{registrationId}/{token}
```

Body keys: `registration`

Response types: `Registration`, `Registration.Response`

Source: `com/groupme/android/welcome/RegistrationUpdateRequest.java`

### `Registration.buildUrl`

```
GET https://v2.groupme.com/registrations/{registrationId}/{token}
```

Response types: `Registration.Response`, `Registration.Response.ActualResponse`

### `Registration.buildUserCreateUrl`

```
POST https://api.groupme.com/v4/users/create
```

Body keys: `date_of_birth`, `device_id`, `force_create`, `name`, `password`, `phone_number`, `registration_id`, `verification_token`

Response type: `UserCreateEnvelope`

Source: `com/groupme/android/registration/api/UserCreateRequest.java`


## Relationships

### `Relationships.deleteUrl`

```
DELETE https://api.groupme.com/v4/relationships/{userId}
```

### `Relationships.getBatchResultsUrl`

```
GET https://api.groupme.com/v4/relationships/batch/{batchId}
```

Optional query: `is_active_last_30_days`

Response type: `Relationship.IndexResponse`

### `Relationships.getContactCreationUrl`

```
POST https://api.groupme.com/v4/relationships/create
```

Body keys: `token`

Source: `com/groupme/android/contacts/AddContactRequest.java`

### `Relationships.getImportContactUrl`

```
POST https://api.groupme.com/v4/relationships/import_contacts
```

Response type: `Relationship.ImportContactResponse`

### `Relationships.getUrl`

```
GET https://api.groupme.com/v4/relationships?include_blocked=true
GET https://api.groupme.com/v4/relationships
GET https://api.groupme.com/v4/relationships?since={since}&include_blocked=true
GET https://api.groupme.com/v4/relationships?since={since}
```

Response type: `Relationship.IndexResponse`


## Report

### `Report.getReportAlbumUrl`

```
GET https://web.groupme.com/abuse_report?album_id={album_id}&media_id={media_id}&group_id={group_id}&langCode={langCode}&mode={mode}&token={token}
```

### `Report.getReportGroupUrl`

```
GET https://web.groupme.com/abuse_report?group_id={group_id}&langCode={langCode}&mode={mode}&token={token}
```

### `Report.getReportMessageUrl`

```
GET https://web.groupme.com/abuse_report?user_id={user_id}&message_id={message_id}&conversation_id={conversation_id}&langCode={langCode}&mode={mode}&token={token}
```

### `Report.getReportUserUrl`

```
GET https://web.groupme.com/abuse_report?user_id={user_id}&langCode={langCode}&mode={mode}&token={token}
```


## Requests

### `Requests.getRequestsCountUrl`

```
GET https://api.groupme.com/v4/requests/count
```

Response types: `RequestCounts`, `RequestCountsResponse.Envelope`

### `Requests.getRequestsUrl`

```
GET https://api.groupme.com/v4/requests
```

Response types: `FindFriendsRequests`, `FindFriendsRequests.Envelope`


## Tokens

### `Tokens.getDestroyUrl`

```
POST https://v2.groupme.com/access_tokens/current/destroy
```

### `Tokens.getLoginUrl`

```
POST https://v2.groupme.com/access_tokens
```

Body keys: `app_id`, `app_version`, `device_id`, `password`, `verification`

Response type: `LoginResponse`

Source: `com/groupme/android/login/MfaLoginRequest.java`


## Users

### `Users.getChangePasswordUrl`

```
POST https://api.groupme.com/v3/users/password
```

Body keys: `password`, `password_current`

Response type: `MfaChannelEnvelope`

Source: `com/groupme/android/change_password/ChangePasswordRequest.java`

### `Users.getChangePhoneNumberUrl`

```
POST https://v2.groupme.com/phone_number_changes
```

Body keys: `client_id`, `phone_number`

Response types: `ChangePhoneNumber`, `ChangePhoneNumberResult`

Source: `com/groupme/android/profile/change_phone_number/ChangePhoneNumberRequest.java`

### `Users.getConfirmNpsSurveyShownUrl`

```
POST https://api.groupme.com/v3/users/me/survey
```

### `Users.getDeleteAccountUrl`

```
POST https://api.groupme.com/v3/user/evict
```

Body keys: `password`

Source: `com/groupme/android/profile/DeleteAccountRequest.java`

### `Users.getDeleteSmsModeUrl`

```
POST https://api.groupme.com/v3/users/sms_mode/delete
```

Body keys: `app_id`, `app_version`, `device_id`, `duration`, `password`, `phone_number`, `registration_id`, `verification`

Response types: `AccountRecoveryEnvelope`, `AccountRecoveryEnvelope.Response`, `LoginResponse`, `Long`

Source: `com/groupme/android/account/SmsModeRequest.java`

### `Users.getDirectoryUsersSearchUrl`

```
GET https://api.groupme.com/v1/search/directory/users?from={from}&per_page={per_page}
```

Response types: `CampusUserInfo.Response`, `CampusUserInfo.UsersResponse`

### `Users.getGenerateBackupCodeUrl`

```
POST https://api.groupme.com/v3/user/mfa/backup
```

Response type: `MfaEnvelope`

### `Users.getInterestsListUrl`

```
GET https://cdn.groupme.com/assets/interestCharms/interestCharms.{lang}.json?version={version}
```

### `Users.getMeSettingsUrl`

```
POST https://api.groupme.com/v3/users/me/settings
```

Body keys: `friend_suggestable`

Source: `com/groupme/android/account/UpdateUserSettingsRequest.java`

### `Users.getMeUrl`

```
GET https://api.groupme.com/v3/users/me
```

Response type: `Profile.Response`

### `Users.getMembershipStatesUrl`

```
GET https://api.groupme.com/v3/memberships/states?page={page}
```

Response type: `MembershipState.MembershipStatesResponse`

### `Users.getMultiFactorAuthUrl`

```
POST https://api.groupme.com/v3/user/mfa
```

Body keys: `mfa`

Response type: `MfaEnvelope`

Source: `com/groupme/android/profile/DisableMultiFactorAuthRequest.java`

### `Users.getOpenMfaChannelUrl`

```
POST https://api.groupme.com/v3/user/mfa/channel
```

Body keys: `channel`, `verification`

Response type: `MfaChannelEnvelope`

Source: `com/groupme/android/multi_factor_auth/CreateMfaChannelRequest.java`

### `Users.getPhoneNumberConfirmUrl`

```
POST https://v2.groupme.com/phone_number_changes/{changeId}/confirm
```

Body keys: `pin`

Source: `com/groupme/android/profile/change_phone_number/VerifyPhoneNumberRequest.java`

### `Users.getProfileSharingEnableUrl`

```
POST https://api.groupme.com/v3/users/features/share
```

Response types: `ProfileSharingResponse`, `ProfileSharingResponse.Response`

### `Users.getSmsModeUrl`

```
POST https://api.groupme.com/v3/users/sms_mode
```

Body keys: `duration`, `registration_id`

Response type: `Long`

Source: `com/groupme/android/account/SmsModeRequest.java`

### `Users.getUpdateUrl`

```
GET,POST https://v2.groupme.com/users/{userId}
```

Body keys: `sleep_until`, `user`

Response types: `Long`, `Profile.LegacyResponse`, `Profile.LegacyResponse.Response`

Source: `com/groupme/android/account/MuteNotificationsRequest.java`

### `Users.getUserDetailsUrl`

```
GET https://api.groupme.com/v4/users/{userId}/share_token/{shareToken}
```

Response types: `ContactData`, `ContactData.Response`

### `Users.getUserInfo`

```
GET https://v2.groupme.com/users/{userId}?include_shared_groups={include_shared_groups}
```

Response types: `Relationship.UserResponse`, `Relationship.UserResponse.Response`


## Venues

### `Venues.getUrl`

```
GET https://api.groupme.com/v1/location/places?
```

Optional query: `ll`, `query`, `near`, `limit`

Response type: `Venue.VenuesResponse`


## Verifications

### `Verifications.buildOtpConfirmUrl`

```
POST https://api.groupme.com/v4/verifications/{verificationId}/confirm
```

Response type: `OtpConfirmEnvelope`

Source: `com/groupme/android/registration/api/OtpConfirmRequest.java`

### `Verifications.getAgeConfirmUrl`

```
POST https://api.groupme.com/v3/verifications/{verificationId}/confirm/dob
```

Body keys: `date_of_birth`, `verification`

Response type: `AgeConfirmEnvelope`

Source: `com/groupme/android/welcome/ConfirmAgeRequest.java`

### `Verifications.getAgeVerificationUrl`

```
POST https://api.groupme.com/v3/verifications/{verificationId}/verify/dob
```

Body keys: `date_of_birth`, `verification`

Response type: `AgeVerificationEnvelope`

Source: `com/groupme/android/welcome/VerifyAgeRequest.java`

### `Verifications.getConfirmPinUrl`

```
POST https://api.groupme.com/v3/verifications/{verificationId}/confirm
```

Body keys: `pin`, `verification`

Source: `com/groupme/android/multi_factor_auth/ConfirmPinRequest.java`

### `Verifications.getInitiateDobUrl`

```
POST https://api.groupme.com/v3/verifications/initiate_dob
```

Response type: `LoginResponse`

### `Verifications.getInitiateVerificationUrl`

```
POST https://api.groupme.com/v3/verifications/{verificationId}/initiate
```

Body keys: `client_id`, `verification`

Source: `com/groupme/android/multi_factor_auth/InitiateVerificationRequest.java`

### `Verifications.getVerificationUrl`

```
GET https://api.groupme.com/v3/verifications/{verificationId}
```

Response types: `LongPinState`, `MfaChannelEnvelope`

