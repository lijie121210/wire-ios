// 
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
// 


#import "ZMConversation+Additions.h"

#import "zmessaging+iOS.h"
#import "Message.h"
#import "ZMUserSession+iOS.h"
#import "ZMUserSession+Additions.h"
#import <AVFoundation/AVFoundation.h>
#import "Analytics+iOS.h"
#import "AnalyticsBase.h"
#import "UIAlertView+Zeta.h"
#import "UIAlertController+Wire.h"
#import "AppDelegate.h"
#import "VoiceChannelController.h"
#import "NotificationWindowRootViewController.h"
#import "NetworkConditionHelper.h"
#import "ZClientViewController.h"
#import "UIApplication+Permissions.h"

#import "Wire-Swift.h"

#if (TARGET_OS_IPHONE)
#import "WAZUIMagic.h"
#endif

#import "Settings.h"
#import "Constants.h"

@implementation ZMConversation (Additions)

- (NSUInteger)participantsCount
{
    return self.activeParticipants.count + self.inactiveParticipants.count;
}

- (ZMConversation *)addParticipants:(NSSet *)participants
{
    if (! participants || participants.count == 0) {
        return self;
    }

    if (self.conversationType == ZMConversationTypeGroup) {
        for (ZMUser *user in participants) {
            [self addParticipant:user];
        }
        
        AnalyticsGroupConversationEvent *event = [AnalyticsGroupConversationEvent eventForAddParticipantsWithCount:participants.count];
        [[Analytics shared] tagEventObject:event];
        return self;
    }
    else if (self.conversationType == ZMConversationTypeOneOnOne &&
               (participants.count > 1 || (participants.count == 1 && ! [self.connectedUser isEqual:participants.anyObject]))) {

        NSMutableArray *listOfPeople = [participants.allObjects mutableCopy];
        [listOfPeople addObject:self.connectedUser];
        ZMConversation *conversation = [ZMConversation insertGroupConversationIntoUserSession:[ZMUserSession sharedSession] withParticipants:listOfPeople];
        AnalyticsGroupConversationEvent *event = [AnalyticsGroupConversationEvent eventForCreatedGroupWithContext:CreatedGroupContextConversation
                                                                                                 participantCount:conversation.activeParticipants.count];
        [[Analytics shared] tagEventObject:event];
        return conversation;
    }

    return self;
}

- (ZMUser *)lastMessageSender
{
    ZMConversationType const conversationType = self.conversationType;
    if (conversationType == ZMConversationTypeGroup) {
        id<ZMConversationMessage>lastMessage = [self.messages lastObject];
        ZMUser *lastMessageSender = lastMessage.sender;
        return lastMessageSender;
    }
    else if (conversationType == ZMConversationTypeOneOnOne || conversationType == ZMConversationTypeConnection) {
        ZMUser *lastMessageSender = self.connectedUser;
        return lastMessageSender;
    }
    else if (conversationType == ZMConversationTypeSelf) {
        return [ZMUser selfUser];
    }
    // ZMConversationTypeInvalid
    return nil;
}

- (void)removeParticipants:(NSArray *)participants
{
    for (ZMUser *user in participants) {
        NSAssert([user isKindOfClass:ZMUser.class], @"Trying to remove a participant that is not a ZMUser!");
        [self removeParticipant:user];
    }
}

- (ZMUser *)firstActiveParticipantOtherThanSelf
{
    ZMUser *selfUser = [ZMUser selfUser];
    for (ZMUser *user in self.activeParticipants) {
        if ( ! [user isEqual:selfUser]) {
            return user;
        }
    }
    return nil;
}

- (ZMUser *)firstActiveCallingParticipantOtherThanSelf
{
    ZMUser *selfUser = [ZMUser selfUser];
    for (ZMUser *user in self.voiceChannel.participants) {
        if ( ! [user isEqual:selfUser]) {
            return user;
        }
    }
    return nil;
}

- (id<ZMConversationMessage>)firstTextMessage
{
    // This is used currently to find the first text message in a connection request
    for (id<ZMConversationMessage>message in self.messages) {
        if ([Message isTextMessage:message]) {
            return message;
        }
    }
    
    return nil;
}

- (id<ZMConversationMessage>)lastTextMessage
{
    id<ZMConversationMessage> message = nil;
    
    // This is only used currently for the 'extras' mode where we show the last line of the conversation in the list
    for (NSInteger i = self.messages.count - 1; i >= 0; i--) {
        id<ZMConversationMessage>currentMessage = [self.messages objectAtIndex:i];
        if ([Message isTextMessage:currentMessage]) {
            message = currentMessage;
            break;
        }
    }
    
    return message;
}

- (BOOL)shouldShowBurstSeparatorForMessage:(id<ZMConversationMessage>)message
{
    // Missed calls should always show timestamp
    if ([Message isSystemMessage:message] &&
        message.systemMessageData.systemMessageType == ZMSystemMessageTypeMissedCall) {
        return YES;
    }

    if ([Message isKnockMessage:message]) {
        return NO;
    }

    if (! [Message isNormalMessage:message] && ! [Message isSystemMessage:message]) {
        return NO;
    }

    NSInteger index = [self.messages indexOfObject:message];
    NSInteger previousIndex = self.messages.count - 1;
    if (index != NSNotFound) {
        previousIndex = index - 1;
    }

    id<ZMConversationMessage>previousMessage = nil;

    // Find a previous message, and use it for time calculation
    while (previousIndex > 0 && self.messages.count > 1 && ! [Message isNormalMessage:previousMessage] && ! [Message isSystemMessage:previousMessage]) {
        previousMessage = [self.messages objectAtIndex:previousIndex--];
    }

    if (! previousMessage) {
        return YES;
    }

    BOOL showTimestamp = NO;

    NSTimeInterval seconds = [message.serverTimestamp timeIntervalSinceDate:previousMessage.serverTimestamp];

    NSTimeInterval referenceSeconds = 300;
#if (TARGET_OS_IPHONE)
    referenceSeconds = [WAZUIMagic floatForIdentifier:@"content.burst_time_interval"];
#endif

    if (seconds > referenceSeconds) {
        showTimestamp = YES;
    }

    return showTimestamp;
}

- (BOOL)selfUserIsActiveParticipant
{
    return [self.activeParticipants containsObject:[ZMUser selfUser]];
}

- (BOOL)shouldDisplayIsTyping
{
    if (! IsTypingEnabled) {
        return NO;
    }

    if (self.conversationType == ZMConversationTypeGroup) {
        return IsTypingInGroupConversationsEnabled;
    }

    return YES;
}

- (BOOL)isCallingSupported
{
    return (self.voiceChannel != nil) && (self.voiceChannel.conversation.activeParticipants.count > 1);
}

- (void)startAudioCallWithCompletionHandler:(void (^)(BOOL))completion
{
    [self joinVoiceChannelWithVideo:NO completionHandler:^(BOOL joined) {
        if (joined) {
            [Analytics shared].sessionSummary.voiceCallsInitiated++;
        }

        if (completion) {
            completion(joined);
        }
    }];
}

- (void)startVideoCallWithCompletionHandler:(void (^)(BOOL))completion
{
    [self warnAboutSlowConnection:^(BOOL abortCall) {
        if (abortCall) {
            return;
        }

        [self joinVoiceChannelWithVideo:YES completionHandler:^(BOOL joined) {
            if (joined) {
                [Analytics shared].sessionSummary.videoCallsInitiated++;

                if (completion) {
                    completion(joined);
                }
            }
        }];
    }];
}

- (void)acceptIncomingCall
{
    [self joinVoiceChannelWithVideo:self.isVideoCall completionHandler:^(BOOL joined) {
        if (joined) {
            [Analytics shared].sessionSummary.incomingCallsAccepted++;
        }
    }];
}

- (void)joinVoiceChannelWithVideo:(BOOL)video completionHandler:(void(^)(BOOL joined))completion
{
    if ([self warnAboutCallInProgress]) {
        if (completion != nil) {
            completion(NO);
        }
        return;
    }

    if ([self warnAboutNoInternetConnection]) {
        if (completion != nil) {
            completion(NO);
        }
        return;
    }

    void (^grantedBlock)(BOOL granted) = ^void(BOOL granted) {
        if (granted) {
            [self joinVoiceChannelWithoutAskingForPermissionWithVideo:video completionHandler:completion];
        } else {
            if (completion != nil) completion(NO);
        }
    };

    [UIApplication wr_requestOrWarnAboutMicrophoneAccess:^(BOOL granted) {
        if (video) {
            [UIApplication wr_requestOrWarnAboutVideoAccess:grantedBlock];
        } else {
            grantedBlock(granted);
        }
    }];
}

- (void)joinVoiceChannelWithoutAskingForPermissionWithVideo:(BOOL)video completionHandler:(void(^)(BOOL joined))completion
{
    [self leaveActiveVoiceChannelAndIgnoreOtherAllIncomingCallsWithCompletionHandler:^{
        ZMVoiceChannelState voiceChannelState = self.voiceChannel.state;
        ZMVoiceChannelConnectionState connectionState = self.voiceChannel.selfUserConnectionState;

        if (connectionState == ZMVoiceChannelConnectionStateNotConnected) {

            __block BOOL joined = YES;
            [[ZMUserSession sharedSession] enqueueChanges:^{
                if (video) {
                    joined = [self.voiceChannel joinVideoCall:nil];
                    [[Analytics shared] tagMediaActionCompleted:ConversationMediaActionVideoCall inConversation:self];
                } else {
                    [self.voiceChannel join];
                    [[Analytics shared] tagMediaActionCompleted:ConversationMediaActionAudioCall inConversation:self];
                }

            } completionHandler:^{
                if (completion != nil) {
                    completion(joined);
                }
            }];
        } else {

            if (voiceChannelState == ZMVoiceChannelStateDeviceTransferReady) {
                UIAlertController *callInProgressAlert =
                [UIAlertController alertControllerWithTitle:NSLocalizedString(@"voice.alert.call_in_progress.title", nil)
                                                    message:NSLocalizedString(@"voice.alert.call_in_progress.message", nil)
                                             preferredStyle:UIAlertControllerStyleAlert];
                [callInProgressAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"voice.alert.call_in_progress.confirm", nil) style:UIAlertActionStyleDefault handler:nil]];
                [[AppDelegate sharedAppDelegate].notificationsWindow.rootViewController presentViewController:callInProgressAlert animated:YES completion:nil];
            }

            if (completion != nil) {
                completion(NO);
            }
        }
    }];
}

- (void)leaveActiveVoiceChannelAndIgnoreOtherAllIncomingCallsWithCompletionHandler:(void(^)())completionHandler
{
    NSArray *nonIdleConversations = [[SessionObjectCache sharedCache] nonIdleVoiceChannelConversations];

    [[ZMUserSession sharedSession] enqueueChanges:^{
        for (ZMConversation *conversation in nonIdleConversations) {
            if (conversation == self) {
                continue;
            }
            else if (conversation.voiceChannel.state == ZMVoiceChannelStateIncomingCall) {
                [conversation.voiceChannel ignoreIncomingCall];
            }
            else if (conversation.voiceChannel.state == ZMVoiceChannelStateSelfConnectedToActiveChannel ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateSelfIsJoiningActiveChannel ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateDeviceTransferReady ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateOutgoingCall ||
                     conversation.voiceChannel.state == ZMVoiceChannelStateOutgoingCallInactive) {
                [conversation.voiceChannel leave];
            }
        }
    } completionHandler:completionHandler];
}

- (void)warnAboutSlowConnection:(void(^)(BOOL abortCall))slowConnectionHandler
{
    if ([NetworkConditionHelper sharedInstance].qualityType == NetworkQualityType2G) {
        UIAlertController *badConnectionController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"error.call.slow_connection.title", @"")
                                                                                         message:NSLocalizedString(@"error.call.slow_connection", @"")
                                                                                  preferredStyle:UIAlertControllerStyleAlert];

        [badConnectionController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"error.call.slow_connection.call_anyway", @"")
                                                                    style:UIAlertActionStyleDefault
                                                                  handler:^(UIAlertAction * _Nonnull action) {
                                                                      slowConnectionHandler(NO);
                                                                  }]];

        [badConnectionController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"general.cancel", @"")
                                                                    style:UIAlertActionStyleCancel
                                                                  handler:^(UIAlertAction * _Nonnull action) {
                                                                      [[ZClientViewController sharedZClientViewController] dismissViewControllerAnimated:YES completion:nil];
                                                                      slowConnectionHandler(YES);
                                                                  }]];

        [[ZClientViewController sharedZClientViewController] presentViewController:badConnectionController animated:YES completion:nil];
    }
    else {
        slowConnectionHandler(NO);
    }
}

- (BOOL)warnAboutNoInternetConnection
{
    if ([[ZMUserSession sharedSession] checkNetworkAndFlashIndicatorIfNecessary]) {
        UIAlertController *noInternetConnectionAlert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"voice.network_error.title", "<missing title>")
                                                                                           message:NSLocalizedString(@"voice.network_error.body", "<voice failed because of network>")
                                                                                 cancelButtonTitle:NSLocalizedString(@"general.ok", "ok string")];
        [[AppDelegate sharedAppDelegate].notificationsWindow.rootViewController presentViewController:noInternetConnectionAlert animated:YES completion:nil];
        return YES;
    }
    return NO;
}

- (BOOL)warnAboutCallInProgress
{
    if ([AppDelegate sharedAppDelegate].notificationWindowController.voiceChannelController.voiceChannelIsJoined) {

        UIAlertController *callInProgressAlert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"voice.alert.call_in_progress.title", @"Calling in progress")
                                                                                     message:NSLocalizedString(@"voice.alert.call_in_progress.message", @"Another device already in call")
                                                                           cancelButtonTitle:NSLocalizedString(@"general.ok", @"ok")];
        [[AppDelegate sharedAppDelegate].notificationsWindow.rootViewController presentViewController:callInProgressAlert animated:YES completion:nil];
        return YES;
    }
    return NO;
}

@end
