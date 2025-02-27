/**
 * @copyright Copyright (c) 2020 Ivan Sein <ivan@nextcloud.com>
 *
 * @author Ivan Sein <ivan@nextcloud.com>
 *
 * @license GNU GPL version 3 or any later version
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "CallViewController.h"

#import <AVKit/AVKit.h>

#import <WebRTC/RTCCameraVideoCapturer.h>
#import <WebRTC/RTCMediaStream.h>
#import <WebRTC/RTCMTLVideoView.h>
#import <WebRTC/RTCVideoTrack.h>

#import "JDStatusBarNotification.h"

#import "CallKitManager.h"
#import "CallParticipantViewCell.h"
#import "NCAPIController.h"
#import "NCAppBranding.h"
#import "NCAudioController.h"
#import "NCCallController.h"
#import "NCDatabaseManager.h"
#import "NCRoomsManager.h"
#import "NCSettingsController.h"
#import "NCSignalingMessage.h"
#import "NCUtils.h"
#import "RoomInfoTableViewController.h"

#import "NextcloudTalk-Swift.h"

typedef NS_ENUM(NSInteger, CallState) {
    CallStateJoining,
    CallStateWaitingParticipants,
    CallStateReconnecting,
    CallStateInCall,
    CallStateSwitchingToAnotherRoom
};

CGFloat const kSidebarWidth                     = 350;
CGFloat const kReactionViewAnimationDuration    = 2.0;
CGFloat const kReactionViewHidingDuration       = 1.0;
CGFloat const kMaxReactionsInScreen             = 5.0;

typedef void (^UpdateCallParticipantViewCellBlock)(CallParticipantViewCell *cell);

@interface PendingCellUpdate : NSObject

@property (nonatomic, strong) NCPeerConnection *peer;
@property (nonatomic, strong) UpdateCallParticipantViewCellBlock block;

@end

@implementation PendingCellUpdate
@end

@interface CallViewController () <NCCallControllerDelegate, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UICollectionViewDataSource, RTCVideoViewDelegate, CallParticipantViewCellDelegate, UIGestureRecognizerDelegate, NCChatTitleViewDelegate>
{
    CallState _callState;
    NSMutableArray *_peersInCall;
    NSMutableDictionary *_videoRenderersDict;
    NSMutableDictionary *_screenRenderersDict;
    NCCallController *_callController;
    NCChatViewController *_chatViewController;
    UINavigationController *_chatNavigationController;
    CGSize _screensharingSize;
    UITapGestureRecognizer *_tapGestureForDetailedView;
    NSTimer *_detailedViewTimer;
    NSTimer *_proximityTimer;
    NSString *_displayName;
    BOOL _isAudioOnly;
    BOOL _isDetailedViewVisible;
    BOOL _userDisabledVideo;
    BOOL _userDisabledSpeaker;
    BOOL _videoCallUpgrade;
    BOOL _hangingUp;
    BOOL _pushToTalkActive;
    BOOL _isHandRaised;
    BOOL _proximityState;
    BOOL _showChatAfterRoomSwitch;
    UIImpactFeedbackGenerator *_buttonFeedbackGenerator;
    CGPoint _localVideoDragStartingPosition;
    CGPoint _localVideoOriginPosition;
    AVRoutePickerView *_airplayView;
    NSMutableArray *_pendingPeerInserts;
    NSMutableArray *_pendingPeerDeletions;
    NSMutableArray *_pendingPeerUpdates;
    NSTimer *_batchUpdateTimer;
    UIImageSymbolConfiguration *_barButtonsConfiguration;
    CGFloat _lastScheduledReaction;
    NSTimer *_callDurationTimer;
}

@property (nonatomic, strong) IBOutlet UIButton *audioMuteButton;
@property (nonatomic, strong) IBOutlet UIButton *speakerButton;
@property (nonatomic, strong) IBOutlet UIButton *videoDisableButton;
@property (nonatomic, strong) IBOutlet UIButton *switchCameraButton;
@property (nonatomic, strong) IBOutlet UIButton *hangUpButton;
@property (nonatomic, strong) IBOutlet UIButton *videoCallButton;
@property (nonatomic, strong) IBOutlet UIButton *recordingButton;
@property (nonatomic, strong) IBOutlet UIButton *lowerHandButton;
@property (nonatomic, strong) IBOutlet UIButton *moreMenuButton;
@property (nonatomic, strong) IBOutlet UICollectionView *collectionView;
@property (nonatomic, strong) IBOutlet UIView *topBarView;
@property (nonatomic, strong) IBOutlet UIStackView *topBarButtonStackView;
@property (nonatomic, strong) IBOutlet UIView *sideBarView;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *collectionViewLeftConstraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *collectionViewBottomConstraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *collectionViewRightConstraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *topBarViewRightContraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *screenshareViewRightContraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *sideBarViewRightConstraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *sideBarViewBottomConstraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *sideBarWidthConstraint;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *stackViewToTitleViewConstraint;

@end

@implementation CallViewController

@synthesize delegate = _delegate;

- (instancetype)initCallInRoom:(NCRoom *)room asUser:(NSString *)displayName audioOnly:(BOOL)audioOnly
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    
    _room = room;
    _displayName = displayName;
    _isAudioOnly = audioOnly;
    _peersInCall = [[NSMutableArray alloc] init];
    _videoRenderersDict = [[NSMutableDictionary alloc] init];
    _screenRenderersDict = [[NSMutableDictionary alloc] init];
    _buttonFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleLight)];
    _pendingPeerInserts = [[NSMutableArray alloc] init];
    _pendingPeerDeletions = [[NSMutableArray alloc] init];
    _pendingPeerUpdates = [[NSMutableArray alloc] init];
    _lastScheduledReaction = 0.0;

    _barButtonsConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:20];
    
    // Use image downloader without cache so I can get 200 or 201 from the avatar requests.
    [AvatarBackgroundImageView setSharedImageDownloader:[[NCAPIController sharedInstance] imageDownloaderNoCache]];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didJoinRoom:) name:NCRoomsManagerDidJoinRoomNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(providerDidEndCall:) name:CallKitManagerDidEndCallNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(providerDidChangeAudioMute:) name:CallKitManagerDidChangeAudioMuteNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(providerWantsToUpgradeToVideoCall:) name:CallKitManagerWantsToUpgradeToVideoCall object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioSessionDidChangeRoute:) name:AudioSessionDidChangeRouteNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioSessionDidActivate:) name:AudioSessionWasActivatedByProviderNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioSessionDidChangeRoutingInformation:) name:AudioSessionDidChangeRoutingInformationNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];

    [NCUserInterfaceController sharedInstance].numberOfAllocatedCallViewControllers += 1;
    
    return self;
}

- (void)startCallWithSessionId:(NSString *)sessionId
{
    _callController = [[NCCallController alloc] initWithDelegate:self inRoom:_room forAudioOnlyCall:_isAudioOnly withSessionId:sessionId andVoiceChatMode:_voiceChatModeAtStart];
    _callController.userDisplayName = _displayName;
    _callController.disableAudioAtStart = _audioDisabledAtStart;
    _callController.disableVideoAtStart = _videoDisabledAtStart;
    _callController.silentCall = _silentCall;
    
    [_callController startCall];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setCallState:CallStateJoining];
    
    _tapGestureForDetailedView = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showDetailedViewWithTimer)];
    [_tapGestureForDetailedView setNumberOfTapsRequired:1];

    UILongPressGestureRecognizer *pushToTalkRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePushToTalk:)];
    [self.audioMuteButton addGestureRecognizer:pushToTalkRecognizer];
    
    [_screensharingView setHidden:YES];
    [_screensharingView setClipsToBounds:YES];

    [self.hangUpButton.layer setCornerRadius:self.hangUpButton.frame.size.height / 2];
    [self.closeScreensharingButton.layer setCornerRadius:16.0f];

    [self.collectionView.layer setCornerRadius:22.0f];
    [self.collectionView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentAlways];

    [self.sideBarView setClipsToBounds:YES];
    [self.sideBarView.layer setCornerRadius:22.0f];

    _airplayView = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(0, 0, 48, 56)];
    _airplayView.tintColor = [UIColor whiteColor];
    _airplayView.activeTintColor = [UIColor whiteColor];
        
    self.audioMuteButton.accessibilityLabel = NSLocalizedString(@"Microphone", nil);
    self.audioMuteButton.accessibilityValue = NSLocalizedString(@"Microphone enabled", nil);
    self.audioMuteButton.accessibilityHint = NSLocalizedString(@"Double tap to enable or disable the microphone", nil);
    self.speakerButton.accessibilityLabel = NSLocalizedString(@"Speaker", nil);
    self.speakerButton.accessibilityValue = NSLocalizedString(@"Speaker disabled", nil);
    self.speakerButton.accessibilityHint = NSLocalizedString(@"Double tap to enable or disable the speaker", nil);
    self.videoDisableButton.accessibilityLabel = NSLocalizedString(@"Camera", nil);
    self.videoDisableButton.accessibilityValue = NSLocalizedString(@"Camera enabled", nil);
    self.videoDisableButton.accessibilityHint = NSLocalizedString(@"Double tap to enable or disable the camera", nil);
    self.hangUpButton.accessibilityLabel = NSLocalizedString(@"Hang up", nil);
    self.hangUpButton.accessibilityHint = NSLocalizedString(@"Double tap to hang up the call", nil);
    self.videoCallButton.accessibilityLabel = NSLocalizedString(@"Camera", nil);
    self.videoCallButton.accessibilityHint = NSLocalizedString(@"Double tap to upgrade this voice call to a video call", nil);
    self.toggleChatButton.accessibilityLabel = NSLocalizedString(@"Chat", nil);
    self.toggleChatButton.accessibilityHint = NSLocalizedString(@"Double tap to show or hide chat view", nil);
    self.recordingButton.accessibilityLabel = NSLocalizedString(@"Recording", nil);
    self.recordingButton.accessibilityHint = NSLocalizedString(@"Double tap to stop recording", nil);
    self.lowerHandButton.accessibilityLabel = NSLocalizedString(@"Lower hand", nil);
    self.lowerHandButton.accessibilityHint = NSLocalizedString(@"Double tap to lower hand", nil);
    self.moreMenuButton.accessibilityLabel = NSLocalizedString(@"More actions", nil);
    self.moreMenuButton.accessibilityHint = NSLocalizedString(@"Double tap to show more actions", nil);

    self.moreMenuButton.showsMenuAsPrimaryAction = YES;

    // Text color should be always white in the call view
    [self.titleView setTitleTextColor:UIColor.whiteColor];
    [self.titleView updateForRoom:_room];

    // The titleView uses the themeColor as a background for the userStatusImage
    // As we always have a black background, we need to change that
    [self.titleView setUserStatusBackgroundColor:UIColor.blackColor];

    self.titleView.delegate = self;
    
    self.collectionView.delegate = self;
    
    [self createWaitingScreen];
    
    // We disableLocalVideo here even if the call controller has not been created just to show the video button as disabled
    // also we set _userDisabledVideo = YES so the proximity sensor doesn't enable it.
    if (_videoDisabledAtStart) {
        _userDisabledVideo = YES;
        [self disableLocalVideo];
    }
    
    if (_voiceChatModeAtStart) {
        _userDisabledSpeaker = YES;
    }

    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    // 'conversation-permissions' capability was not added in Talk 13 release, so we check for 'direct-mention-flag' capability
    // as a workaround.
    BOOL serverSupportsConversationPermissions =
    [[NCDatabaseManager sharedInstance] serverHasTalkCapability:kCapabilityConversationPermissions forAccountId:activeAccount.accountId] ||
    [[NCDatabaseManager sharedInstance] serverHasTalkCapability:kCapabilityDirectMentionFlag forAccountId:activeAccount.accountId];
    if (serverSupportsConversationPermissions) {
        [self setAudioMuteButtonEnabled:(_room.permissions & NCPermissionCanPublishAudio)];
        [self setVideoDisableButtonEnabled:(_room.permissions & NCPermissionCanPublishVideo)];
    }
    
    [self.collectionView registerNib:[UINib nibWithNibName:kCallParticipantCellNibName bundle:nil] forCellWithReuseIdentifier:kCallParticipantCellIdentifier];
    [self.collectionView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
    
    UIPanGestureRecognizer *localVideoDragGesturure = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(localVideoDragged:)];
    [self.localVideoView addGestureRecognizer:localVideoDragGesturure];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sensorStateChange:)
                                                 name:UIDeviceProximityStateDidChangeNotification object:nil];

    // callStartTime is only available if we have the "recording-v1" capability
    if ([[NCDatabaseManager sharedInstance] serverHasTalkCapability:kCapabilityRecordingV1]) {
        _callDurationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(callDurationTimerUpdate) userInfo:nil repeats:YES];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    [self adjustConstraints];
    [self.collectionView.collectionViewLayout invalidateLayout];
    
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        [self setLocalVideoRect];
        [self->_screensharingView resizeContentView];
        [self adjustTopBar];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
    }];
}

- (void)viewSafeAreaInsetsDidChange
{
    [super viewSafeAreaInsetsDidChange];
    [self adjustConstraints];
    [self setLocalVideoRect];
    [self adjustTopBar];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self setSideBarVisible:NO animated:NO withCompletion:nil];
    [self adjustConstraints];
    [self setLocalVideoRect];
    [self adjustSpeakerButton];
    [self adjustTopBar];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [[UIDevice currentDevice] setProximityMonitoringEnabled:NO];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    [[UIDevice currentDevice] setProximityMonitoringEnabled:YES];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

- (void)dealloc
{
    NSLog(@"CallViewController dealloc");
    [NCUserInterfaceController sharedInstance].numberOfAllocatedCallViewControllers -= 1;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    // No push-to-talk while in chat
    if (!_chatNavigationController) {
        for (UIPress* press in presses) {
            if (press.key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar) {
                [self pushToTalkStart];
                
                return;
            }
        }
    }
    
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
    // No push-to-talk while in chat
    if (!_chatNavigationController) {
        for (UIPress* press in presses) {
            if (press.key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar) {
                [self pushToTalkEnd];
                
                return;
            }
        }
    }
    
    [super pressesEnded:presses withEvent:event];
}

#pragma mark - App lifecycle notifications

-(void)appDidBecomeActive:(NSNotification*)notification
{
    if (!_isAudioOnly && _callController && !_userDisabledVideo) {
        // Only enable video if it was not disabled by the user.
        [self enableLocalVideo];
    }
}

-(void)appWillResignActive:(NSNotification*)notification
{
    if (!_isAudioOnly && _callController) {
        [_callController getVideoEnabledStateWithCompletionBlock:^(BOOL isEnabled) {
            if (isEnabled) {
                // Disable video when the app moves to the background as we can't access the camera anymore.
                [self disableLocalVideo];
            }
        }];
    }
}

#pragma mark - Rooms manager notifications

- (void)didJoinRoom:(NSNotification *)notification
{
    NSString *token = [notification.userInfo objectForKey:@"token"];
    if (![token isEqualToString:_room.token]) {
        return;
    }
    
    NSError *error = [notification.userInfo objectForKey:@"error"];
    if (error) {
        [self presentJoinError:[notification.userInfo objectForKey:@"errorReason"]];
        return;
    }
    
    NCRoomController *roomController = [notification.userInfo objectForKey:@"roomController"];
    if (!_callController) {
        [self startCallWithSessionId:roomController.userSessionId];
    }

    [self.titleView updateForRoom:_room];
}

- (void)providerDidChangeAudioMute:(NSNotification *)notification
{
    NSString *roomToken = [notification.userInfo objectForKey:@"roomToken"];
    if (![roomToken isEqualToString:_room.token]) {
        return;
    }
    
    BOOL isMuted = [[notification.userInfo objectForKey:@"isMuted"] boolValue];
    [self setAudioMuted:isMuted];
}

- (void)providerDidEndCall:(NSNotification *)notification
{
    NSString *roomToken = [notification.userInfo objectForKey:@"roomToken"];
    if (![roomToken isEqualToString:_room.token]) {
        return;
    }
    
    [self hangupForAll:NO];
}

- (void)providerWantsToUpgradeToVideoCall:(NSNotification *)notification
{
    NSString *roomToken = [notification.userInfo objectForKey:@"roomToken"];
    if (![roomToken isEqualToString:_room.token]) {
        return;
    }
    
    if (_isAudioOnly) {
        [self showUpgradeToVideoCallDialog];
    }
}

#pragma mark - Audio controller notifications

- (void)audioSessionDidChangeRoute:(NSNotification *)notification
{
    [self adjustSpeakerButton];
}

- (void)audioSessionDidActivate:(NSNotification *)notification
{
    [self adjustSpeakerButton];
}

- (void)audioSessionDidChangeRoutingInformation:(NSNotification *)notification
{
    [self adjustSpeakerButton];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self adjustMoreButtonMenu];
    });
}

#pragma mark - Local video

- (void)setLocalVideoRect
{
    CGSize localVideoSize;
    
    CGFloat width = [UIScreen mainScreen].bounds.size.width / 6;
    CGFloat height = [UIScreen mainScreen].bounds.size.height / 6;
    
    NSString *videoResolution = [[[NCSettingsController sharedInstance] videoSettingsModel] currentVideoResolutionSettingFromStore];
    NSString *localVideoRes = [[[NCSettingsController sharedInstance] videoSettingsModel] readableResolution:videoResolution];

    // When running on MacOS the camera will always be in portrait mode
    if ([localVideoRes isEqualToString:@"Low"] || [localVideoRes isEqualToString:@"Normal"]) {
        if (width < height || [NCUtils isiOSAppOnMac]) {
            localVideoSize = CGSizeMake(height * 3/4, height);
        } else {
            localVideoSize = CGSizeMake(width, width * 3/4);
        }
    } else {
        if (width < height || [NCUtils isiOSAppOnMac]) {
            localVideoSize = CGSizeMake(height * 9/16, height);
        } else {
            localVideoSize = CGSizeMake(width, width * 9/16);
        }
    }

    UIEdgeInsets safeAreaInsets = self.view.safeAreaInsets;
    _localVideoOriginPosition = CGPointMake(16 + safeAreaInsets.left + _collectionViewLeftConstraint.constant, 80 + safeAreaInsets.top);

    CGRect localVideoRect = CGRectMake(_localVideoOriginPosition.x, _localVideoOriginPosition.y, localVideoSize.width, localVideoSize.height);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_localVideoView.frame = localVideoRect;
        self->_localVideoView.layer.cornerRadius = 15.0f;
        self->_localVideoView.layer.masksToBounds = YES;
    });
}

#pragma mark - Proximity sensor

- (void)sensorStateChange:(NSNotificationCenter *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_proximityTimer invalidate];
        self->_proximityTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(adjustProximityState) userInfo:nil repeats:NO];
    });
}

- (void)adjustProximityState
{
    BOOL currentProximityState = [[UIDevice currentDevice] proximityState];

    if (currentProximityState == _proximityState) {
        return;
    }

    _proximityState = currentProximityState;

    if (!_isAudioOnly) {
        if (_proximityState == YES) {
            [self disableLocalVideo];
            [self disableSpeaker];
        } else {
            // Only enable video if it was not disabled by the user.
            if (!_userDisabledVideo) {
                [self enableLocalVideo];
            }
            if (!_userDisabledSpeaker) {
                [self enableSpeaker];
            }
        }
    }

    [self pushToTalkEnd];
}

#pragma mark - User Interface

- (void)setCallState:(CallState)state
{
    _callState = state;
    switch (state) {
        case CallStateJoining:
        case CallStateWaitingParticipants:
        case CallStateReconnecting:
        {
            [self showWaitingScreen];
            [self invalidateDetailedViewTimer];
            [self showDetailedView];
            [self removeTapGestureForDetailedView];
        }
            break;
            
        case CallStateInCall:
        {
            [self hideWaitingScreen];
            if (!_isAudioOnly) {
                [self addTapGestureForDetailedView];
                [self showDetailedViewWithTimer];
            }
        }
            break;

        case CallStateSwitchingToAnotherRoom:
        {
            [self showWaitingScreen];
            [self invalidateDetailedViewTimer];
            [self showDetailedView];
            [self removeTapGestureForDetailedView];
        }
            break;

        default:
            break;
    }
}

- (void)setCallStateForPeersInCall
{
    if ([_peersInCall count] > 0) {
        if (_callState != CallStateInCall) {
            [self setCallState:CallStateInCall];
        }
    } else {
        if (_callState == CallStateInCall) {
            [self setCallState:CallStateWaitingParticipants];
        }
    }
}

- (void)createWaitingScreen
{
    self.avatarBackgroundImageView.backgroundColor = [NCAppBranding themeColor];

    if (_room.type == kNCRoomTypeOneToOne) {
        UIColor *bgColor = [[ColorGenerator shared] usernameToColor:self.room.displayName];
        [self.avatarBackgroundImageView setBackgroundColor:bgColor];
        self.avatarBackgroundImageView.backgroundColor = [self.avatarBackgroundImageView.backgroundColor colorWithAlphaComponent:0.8];
    }
    
    [self setWaitingScreenText];
}

- (void)setWaitingScreenText
{
    NSString *waitingMessage = NSLocalizedString(@"Waiting for others to join call …", nil);
    if (_room.type == kNCRoomTypeOneToOne) {
        waitingMessage = [NSString stringWithFormat:NSLocalizedString(@"Waiting for %@ to join call …", nil), _room.displayName];
    }
    
    if (_callState == CallStateReconnecting) {
        waitingMessage = NSLocalizedString(@"Connecting to the call …", nil);
    }
    
    if (_callState == CallStateSwitchingToAnotherRoom) {
        waitingMessage = NSLocalizedString(@"Switching to another conversation …", nil);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.waitingLabel.text = waitingMessage;
    });
}

- (void)showWaitingScreen
{
    [self setWaitingScreenText];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.collectionView.backgroundView = self.waitingView;
    });
}

- (void)hideWaitingScreen
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.collectionView.backgroundView = nil;
    });
}

- (void)addTapGestureForDetailedView
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view addGestureRecognizer:self->_tapGestureForDetailedView];
    });
}

- (void)removeTapGestureForDetailedView
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view removeGestureRecognizer:self->_tapGestureForDetailedView];
    });
}

- (void)showDetailedView
{
    _isDetailedViewVisible = YES;
    [self showPeersInfo];
}

- (void)showDetailedViewWithTimer
{
    if (_isDetailedViewVisible) {
        [self hideDetailedView];
    } else {
        [self showDetailedView];
        [self setDetailedViewTimer];
    }
}

- (void)hideDetailedView
{
    // Keep detailed view visible while push to talk is active
    if (_pushToTalkActive) {
        [self setDetailedViewTimer];
        return;
    }
    
    _isDetailedViewVisible = NO;
    [self hidePeersInfo];
    [self invalidateDetailedViewTimer];
}

- (void)setAudioMuteButtonActive:(BOOL)active
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *micStatusString = nil;

        if (active) {
            micStatusString = NSLocalizedString(@"Microphone enabled", nil);
            [self->_audioMuteButton setImage:[UIImage systemImageNamed:@"mic.fill" withConfiguration:self->_barButtonsConfiguration] forState:UIControlStateNormal];
        } else {
            micStatusString = NSLocalizedString(@"Microphone disabled", nil);
            [self->_audioMuteButton setImage:[UIImage systemImageNamed:@"mic.slash.fill" withConfiguration:self->_barButtonsConfiguration] forState:UIControlStateNormal];
        }

        self->_audioMuteButton.accessibilityValue = micStatusString;
    });
}

- (void)setAudioMuteButtonEnabled:(BOOL)enabled
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_audioMuteButton.enabled = enabled;
    });
}

- (void)setVideoDisableButtonActive:(BOOL)active
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *cameraStatusString = nil;

        if (active) {
            cameraStatusString = NSLocalizedString(@"Camera enabled", nil);
            [self->_videoDisableButton setImage:[UIImage systemImageNamed:@"video.fill" withConfiguration:self->_barButtonsConfiguration] forState:UIControlStateNormal];
        } else {
            cameraStatusString = NSLocalizedString(@"Camera disabled", nil);
            [self->_videoDisableButton setImage:[UIImage systemImageNamed:@"video.slash.fill" withConfiguration:self->_barButtonsConfiguration] forState:UIControlStateNormal];
        }

        self->_videoDisableButton.accessibilityValue = cameraStatusString;
    });
}

- (void)setVideoDisableButtonEnabled:(BOOL)enabled
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_videoDisableButton.enabled = enabled;
    });
}

- (void)setLocalVideoViewHidden:(BOOL)hidden
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_localVideoView setHidden:hidden];
    });
}

- (void)adjustTopBar
{
    dispatch_async(dispatch_get_main_queue(), ^{
        // Enable/Disable video buttons
        self->_videoDisableButton.hidden = self->_isAudioOnly;
        self->_switchCameraButton.hidden = self->_isAudioOnly;
        self->_videoCallButton.hidden = !self->_isAudioOnly;

        self->_lowerHandButton.hidden = !self->_isHandRaised;

        // Only when the server supports recording-v1 we have access to callStartTime, otherwise hide the label
        self->_callTimeLabel.hidden = ![[NCDatabaseManager sharedInstance] serverHasTalkCapability:kCapabilityRecordingV1];

        NCAudioController *audioController = [NCAudioController sharedInstance];
        self->_speakerButton.hidden = ![audioController isAudioRouteChangeable];

        BOOL hideRecordingButton = ![self->_room callRecordingIsInActiveState];
        self->_recordingButton.hidden = hideRecordingButton;

        // Differ between starting a call recording and an actual running call recording
        if (self->_room.callRecording == NCCallRecordingStateVideoStarting || self->_room.callRecording == NCCallRecordingStateAudioStarting) {
            self->_recordingButton.tintColor = UIColor.systemGrayColor;
        } else {
            self->_recordingButton.tintColor = UIColor.systemRedColor;
        }

        // When the horizontal size is compact (e.g. iPhone portrait) we don't show the 'End call' text on the button
        // Don't make assumptions about the device here, because with split screen even an iPad can have a compact width
        if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact) {
            [self setHangUpButtonWithTitle:NO];
        } else {
            [self setHangUpButtonWithTitle:YES];
        }
        
        // Make sure we get the correct frame for the stack view, after changing the visibility of buttons
        [self->_topBarView setNeedsLayout];
        [self->_topBarView layoutIfNeeded];

        // Hide titleView if we don't have enough space
        // Don't do it in one go, as then we will have some jumping
        if (self->_topBarButtonStackView.frame.origin.x < 200) {
            [self setHangUpButtonWithTitle:NO];
            [self->_titleView setHidden:YES];
            [self->_stackViewToTitleViewConstraint setActive:NO];
        } else {
            [self->_titleView setHidden:NO];
            [self->_stackViewToTitleViewConstraint setActive:YES];
        }

        // Need to update the layout again, if we changed it here
        [self->_topBarView setNeedsLayout];
        [self->_topBarView layoutIfNeeded];

        // Hide the speaker button to make some more room for higher priority buttons
        // This should only be the case for iPhone SE (1st Gen) when recording is active and/or hand is raised
        if (self->_topBarButtonStackView.frame.origin.x < 0) {
            self->_speakerButton.hidden = YES;
        }

        [self->_topBarView setNeedsLayout];
        [self->_topBarView layoutIfNeeded];

        if (self->_topBarButtonStackView.frame.origin.x < 0) {
            self->_callTimeLabel.hidden = YES;
        }

        [self adjustMoreButtonMenu];

        if ([self->_room canModerate] && [[NCDatabaseManager sharedInstance] serverHasTalkCapability:kCapabilityPublishingPermissions]) {
            __weak typeof(self) weakSelf = self;
            UIAction *hangupForAllAction = [UIAction actionWithTitle:NSLocalizedString(@"End call for everyone", @"") image:[UIImage systemImageNamed:@"phone.down.fill"] identifier:nil handler:^(UIAction *action) {
                [weakSelf hangupForAll:YES];
            }];

            hangupForAllAction.attributes = UIMenuElementAttributesDestructive;

            self.hangUpButton.menu = [UIMenu menuWithTitle:@"" children:@[hangupForAllAction]];
        }
    });
}

- (void)setHangUpButtonWithTitle:(BOOL)title
{
    if (title) {
        [_hangUpButton setTitle:NSLocalizedString(@"End call", nil) forState:UIControlStateNormal];
        [_hangUpButton setTitleColor:[UIColor grayColor] forState:UIControlStateHighlighted];
        [_hangUpButton setContentEdgeInsets:UIEdgeInsetsMake(0, 16, 0, 24)];
        [_hangUpButton setTitleEdgeInsets:UIEdgeInsetsMake(0, 8, 0, -8)];
    } else {
        [_hangUpButton setTitle:@"" forState:UIControlStateNormal];
        [_hangUpButton setContentEdgeInsets:UIEdgeInsetsZero];
        [_hangUpButton setTitleEdgeInsets:UIEdgeInsetsZero];
    }
}

- (void)adjustConstraints
{
    CGFloat rightConstraintConstant = [self getRightSideConstraintConstant];
    [self->_collectionViewRightConstraint setConstant:rightConstraintConstant];

    if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact) {
        [self->_collectionViewLeftConstraint setConstant:0.0f];
    } else {
        [self->_collectionViewLeftConstraint setConstant:8.0f];
    }

    if (self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact) {
        [self->_collectionViewBottomConstraint setConstant:0.0f];
        [self->_sideBarViewBottomConstraint setConstant:0.0f];
    } else {
        [self->_collectionViewBottomConstraint setConstant:8.0f];
        [self->_sideBarViewBottomConstraint setConstant:8.0f];
    }
}

- (void)adjustMoreButtonMenu
{
    // When we target iOS 15, we might want to use an uncached UIDeferredMenuElement

    NSMutableArray *items = [[NSMutableArray alloc] init];
    __weak typeof(self) weakSelf = self;

    // Add speaker button to menu if it was hidden from topbar
    NCAudioController *audioController = [NCAudioController sharedInstance];
    if ([self.speakerButton isHidden] && [audioController isAudioRouteChangeable]) {
        // TODO: Adjust for AirPlay?
        UIImage *speakerImage = [UIImage systemImageNamed:@"speaker.wave.3.fill"];
        NSString *speakerActionTitle = NSLocalizedString(@"Speaker", nil);

        if (![NCAudioController sharedInstance].isSpeakerActive) {
            speakerImage = [UIImage systemImageNamed:@"speaker.slash.fill"];
        }

        UIAction *speakerAction = [UIAction actionWithTitle:speakerActionTitle image:speakerImage identifier:nil handler:^(UIAction *action) {
            [self speakerButtonPressed:nil];
        }];

        [items addObject:speakerAction];
    }

    // Raise hand
    if ([[NCDatabaseManager sharedInstance] serverHasTalkCapability:kCapabilityRaiseHand]) {
        NSString *raiseHandTitel = NSLocalizedString(@"Raise hand", nil);

        if (_isHandRaised) {
            raiseHandTitel = NSLocalizedString(@"Lower hand", nil);
        }

        UIAction *raiseHandAction = [UIAction actionWithTitle:raiseHandTitel image:[UIImage systemImageNamed:@"hand.raised.fill"] identifier:nil handler:^(UIAction *action) {
            __strong typeof(self) strongSelf = weakSelf;

            [strongSelf->_callController raiseHand:!strongSelf->_isHandRaised];
            strongSelf->_isHandRaised = !strongSelf->_isHandRaised;
            [strongSelf adjustTopBar];
        }];

        [items addObject:raiseHandAction];
    }

    // Send a reaction
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    ServerCapabilities *serverCapabilities  = [[NCDatabaseManager sharedInstance] serverCapabilitiesForAccountId:activeAccount.accountId];

    if (serverCapabilities.callReactions.count > 0) {
        NSMutableArray *reactionItems = [[NSMutableArray alloc] init];

        for (NSString *reaction in serverCapabilities.callReactions) {
            UIAction *reactionAction = [UIAction actionWithTitle:reaction image:nil identifier:nil handler:^(UIAction *action) {
                __strong typeof(self) strongSelf = weakSelf;

                [strongSelf->_callController sendReaction:reaction];
                [strongSelf addReaction:reaction fromUser:activeAccount.userDisplayName];
            }];

            [reactionItems addObject:reactionAction];
        }

        UIMenu *reactionMenu;

        if (@available(iOS 16.0, *)) {
            NSInteger currentItemsCount = 0;
            NSMutableArray *temporaryReactionItems = [[NSMutableArray alloc] init];
            NSMutableArray *temporaryReactionMenus = [[NSMutableArray alloc] init];

            for (UIAction *reactionAction in reactionItems) {
                currentItemsCount += 1;

                [temporaryReactionItems addObject:reactionAction];

                if (currentItemsCount >= 2) {
                    UIMenu *inlineReactionMenu = [UIMenu menuWithTitle:@""
                                                                 image:nil
                                                            identifier:nil
                                                               options:UIMenuOptionsDisplayInline
                                                              children:temporaryReactionItems];

                    inlineReactionMenu.preferredElementSize = UIMenuElementSizeSmall;

                    [temporaryReactionMenus addObject:inlineReactionMenu];
                    temporaryReactionItems = [[NSMutableArray alloc] init];
                    currentItemsCount = 0;
                }
            }

            if (currentItemsCount > 0) {
                UIMenu *inlineReactionMenu = [UIMenu menuWithTitle:@""
                                                             image:nil
                                                        identifier:nil
                                                           options:UIMenuOptionsDisplayInline
                                                          children:temporaryReactionItems];

                inlineReactionMenu.preferredElementSize = UIMenuElementSizeSmall;

                [temporaryReactionMenus addObject:inlineReactionMenu];
            }

            reactionMenu = [UIMenu menuWithTitle:NSLocalizedString(@"Send a reaction", nil)
                                           image:[UIImage systemImageNamed:@"face.smiling"]
                                      identifier:nil
                                         options:0
                                        children:temporaryReactionMenus];

        } else {
            // Show the menu as one long list on devices < iOS 16
            reactionMenu = [UIMenu menuWithTitle:NSLocalizedString(@"Send a reaction", nil)
                                           image:[UIImage systemImageNamed:@"face.smiling"]
                                      identifier:nil
                                         options:0
                                        children:reactionItems];
        }





        [items addObject:reactionMenu];
    }

    // Start/Stop recording
    if ([self->_room isUserOwnerOrModerator] && [[NCSettingsController sharedInstance] isRecordingEnabled]) {
        UIImage *recordingImage = [UIImage systemImageNamed:@"record.circle.fill"];
        NSString *recordingActionTitle = NSLocalizedString(@"Start recording", nil);

        if ([self->_room callRecordingIsInActiveState]) {
            recordingImage = [UIImage systemImageNamed:@"stop.circle.fill"];
            recordingActionTitle = NSLocalizedString(@"Stop recording", nil);
        }

        UIAction *recordingAction = [UIAction actionWithTitle:recordingActionTitle image:recordingImage identifier:nil handler:^(UIAction *action) {
            __strong typeof(self) strongSelf = weakSelf;

            if ([strongSelf->_room callRecordingIsInActiveState]) {
                [strongSelf showStopRecordingConfirmationDialog];
            } else {
                [strongSelf->_callController startRecording];
            }
        }];

        [items addObject:recordingAction];
    }

    self.moreMenuButton.menu = [UIMenu menuWithTitle:@"" children:items];
}

- (void)adjustSpeakerButton
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NCAudioController *audioController = [NCAudioController sharedInstance];
        [self setSpeakerButtonActive:audioController.isSpeakerActive];

        // If the visibility of the speaker button does not reflect the route changeability
        // we need to try and adjust the top bar
        if (self->_speakerButton.isHidden == [audioController isAudioRouteChangeable]) {
            [self adjustTopBar];
        }

        // Show AirPlay button if there are more audio routes available
        if (audioController.numberOfAvailableInputs > 1) {
            [self setSpeakerButtonWithAirplayButton];
        } else {
            [self->_airplayView removeFromSuperview];
        }
    });
}

- (void)setDetailedViewTimer
{
    [self invalidateDetailedViewTimer];
    _detailedViewTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(hideDetailedView) userInfo:nil repeats:NO];
}

- (void)invalidateDetailedViewTimer
{
    [_detailedViewTimer invalidate];
    _detailedViewTimer = nil;
}

- (void)presentJoinError:(NSString *)alertMessage
{
    NSString *alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Could not join %@ call", nil), _room.displayName];
    if (_room.type == kNCRoomTypeOneToOne) {
        alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Could not join call with %@", nil), _room.displayName];
    }
    
    UIAlertController * alert = [UIAlertController alertControllerWithTitle:alertTitle
                                                                    message:alertMessage
                                                             preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* okButton = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction * _Nonnull action) {
                                                         [self hangupForAll:NO];
                                                     }];
    [alert addAction:okButton];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)adjustLocalVideoPositionFromOriginPosition:(CGPoint)position
{
    UIEdgeInsets safeAreaInsets = _localVideoView.superview.safeAreaInsets;

    CGFloat edgeInsetTop = 16 + _topBarView.frame.origin.y + _topBarView.frame.size.height;
    CGFloat edgeInsetLeft = 16 + safeAreaInsets.left + _collectionViewLeftConstraint.constant;
    CGFloat edgeInsetBottom = 16 + safeAreaInsets.bottom + _collectionViewBottomConstraint.constant;
    CGFloat edgeInsetRight = 16 + safeAreaInsets.right + _collectionViewRightConstraint.constant;

    UIEdgeInsets edgeInsets = UIEdgeInsetsMake(edgeInsetTop, edgeInsetLeft, edgeInsetBottom, edgeInsetRight);

    CGSize parentSize = _localVideoView.superview.bounds.size;
    CGSize viewSize = _localVideoView.bounds.size;

    // Adjust left
    if (position.x < edgeInsets.left) {
        position = CGPointMake(edgeInsets.left, position.y);
    }

    // Adjust top
    if (position.y < edgeInsets.top) {
        position = CGPointMake(position.x, edgeInsets.top);
    }

    // Adjust right
    if (position.x > parentSize.width - viewSize.width - edgeInsets.right) {
        position = CGPointMake(parentSize.width - viewSize.width - edgeInsets.right, position.y);
    }

    // Adjust bottom
    if (position.y > parentSize.height - viewSize.height - edgeInsets.bottom) {
        position = CGPointMake(position.x, parentSize.height - viewSize.height - edgeInsets.bottom);
    }

    CGRect frame = _localVideoView.frame;
    frame.origin.x = position.x;
    frame.origin.y = position.y;

    [UIView animateWithDuration:0.3 animations:^{
        self->_localVideoView.frame = frame;
    }];
}

- (void)localVideoDragged:(UIPanGestureRecognizer *)gesture
{
    if (gesture.view == _localVideoView) {
        if (gesture.state == UIGestureRecognizerStateBegan) {
            _localVideoDragStartingPosition = gesture.view.center;
        } else if (gesture.state == UIGestureRecognizerStateChanged) {
            CGPoint translation = [gesture translationInView:gesture.view];
            _localVideoView.center = CGPointMake(_localVideoDragStartingPosition.x + translation.x, _localVideoDragStartingPosition.y + translation.y);
        } else if (gesture.state == UIGestureRecognizerStateEnded) {
            _localVideoOriginPosition = gesture.view.frame.origin;
            [self adjustLocalVideoPositionFromOriginPosition:_localVideoOriginPosition];
        }
    }
}

- (void)callDurationTimerUpdate
{
    // In case we are the ones who start the call, we don't have the server-side callStartTime, so we set it locally
    if (self.room.callStartTime == 0) {
        self.room.callStartTime = [[NSDate date] timeIntervalSince1970];
    }

    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    long callDuration = currentTimestamp - self.room.callStartTime;
    long oneHourInSeconds = 60 * 60;

    long hours = callDuration / 3600;
    long minutes = (callDuration / 60) % 60;
    long seconds = callDuration % 60;

    if (hours > 0) {
        [self.callTimeLabel setText:[NSString stringWithFormat:@"%lu:%02lu:%02lu", hours, minutes, seconds]];
    } else {
        [self.callTimeLabel setText:[NSString stringWithFormat:@"%02lu:%02lu", minutes, seconds]];
    }

    if (self->_topBarButtonStackView.frame.origin.x < 0) {
        [self adjustTopBar];
    }

    if (callDuration == oneHourInSeconds) {
        NSString *callRunningFor1h = NSLocalizedString(@"The call has been running for one hour", nil);
        [[JDStatusBarNotificationPresenter sharedPresenter] presentWithText:callRunningFor1h dismissAfterDelay:7.0 includedStyle:JDStatusBarNotificationIncludedStyleDark];
    }
}

#pragma mark - Call actions

-(void)handlePushToTalk:(UILongPressGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        [self pushToTalkStart];
    } else if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        [self pushToTalkEnd];
    }
}

- (void)pushToTalkStart
{
    if (!_callController) {
        return;
    }

    [_callController getAudioEnabledStateWithCompletionBlock:^(BOOL isEnabled) {
        if (!isEnabled) {
            [self setAudioMuted:NO];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_buttonFeedbackGenerator impactOccurred];
                self->_pushToTalkActive = YES;
            });
        }
    }];
}

- (void)pushToTalkEnd
{
    if (_pushToTalkActive) {
        [self setAudioMuted:YES];

        _pushToTalkActive = NO;
    }
}

- (IBAction)audioButtonPressed:(id)sender
{
    if (!_callController) {
        return;
    }

    [_callController getAudioEnabledStateWithCompletionBlock:^(BOOL isEnabled) {
        if ([CallKitManager isCallKitAvailable]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[CallKitManager sharedInstance] changeAudioMuted:isEnabled forCall:self->_room.token];
            });
        } else {
            [self setAudioMuted:isEnabled];
        }
    }];
}

- (void)forceMuteAudio
{
    if (!_callController) {
        return;
    }

    [_callController getAudioEnabledStateWithCompletionBlock:^(BOOL isEnabled) {
        if (!isEnabled) {
            // We are already muted, no need to mute again
            return;
        }

        [self setAudioMuted:YES];

        NSString *micDisabledString = NSLocalizedString(@"Microphone disabled", nil);
        NSString *forceMutedString = NSLocalizedString(@"You have been muted by a moderator", nil);

        dispatch_async(dispatch_get_main_queue(), ^{
            [[JDStatusBarNotificationPresenter sharedPresenter] presentWithTitle:micDisabledString subtitle:forceMutedString includedStyle:JDStatusBarNotificationIncludedStyleDark completion:nil];
            [[JDStatusBarNotificationPresenter sharedPresenter] dismissAfterDelay:7.0];
        });
    }];
}

- (void)setAudioMuted:(BOOL)isMuted
{
    [_callController enableAudio:!isMuted];
    [self setAudioMuteButtonActive:!isMuted];
}

- (IBAction)videoButtonPressed:(id)sender
{
    if (!_callController) {
        return;
    }
    
    [_callController getVideoEnabledStateWithCompletionBlock:^(BOOL isEnabled) {
        [self setLocalVideoEnabled:!isEnabled];
        self->_userDisabledVideo = isEnabled;
    }];
}

- (void)disableLocalVideo
{
    [self setLocalVideoEnabled:NO];
}

- (void)enableLocalVideo
{
    [self setLocalVideoEnabled:YES];
}

- (void)setLocalVideoEnabled:(BOOL)enabled
{
    [_callController enableVideo:enabled];

    [self setLocalVideoViewHidden:!enabled];
    [self setVideoDisableButtonActive:enabled];
}

- (IBAction)switchCameraButtonPressed:(id)sender
{
    [_callController switchCamera];
    [self flipLocalVideoView];
}

- (void)flipLocalVideoView
{
    CATransition *animation = [CATransition animation];
    animation.duration = .5f;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    animation.type = @"oglFlip";
    animation.subtype = kCATransitionFromRight;
    
    [self.localVideoView.layer addAnimation:animation forKey:nil];
}

- (IBAction)speakerButtonPressed:(id)sender
{
    if ([NCAudioController sharedInstance].isSpeakerActive) {
        [self disableSpeaker];
        _userDisabledSpeaker = YES;
    } else {
        [self enableSpeaker];
        _userDisabledSpeaker = NO;
    }

    [self adjustMoreButtonMenu];
}

- (void)disableSpeaker
{
    [self setSpeakerButtonActive:NO];

    [[WebRTCCommon shared] dispatch:^{
        [[NCAudioController sharedInstance] setAudioSessionToVoiceChatMode];
    }];
}

- (void)enableSpeaker
{
    [self setSpeakerButtonActive:YES];

    [[WebRTCCommon shared] dispatch:^{
        [[NCAudioController sharedInstance] setAudioSessionToVideoChatMode];
    }];
}

- (void)setSpeakerButtonActive:(BOOL)active
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *speakerStatusString = nil;

        if (active) {
            speakerStatusString = NSLocalizedString(@"Speaker enabled", nil);
            [self.speakerButton setImage:[UIImage systemImageNamed:@"speaker.wave.3.fill" withConfiguration:self->_barButtonsConfiguration] forState:UIControlStateNormal];
        } else {
            speakerStatusString = NSLocalizedString(@"Speaker disabled", nil);
            [self.speakerButton setImage:[UIImage systemImageNamed:@"speaker.slash.fill" withConfiguration:self->_barButtonsConfiguration] forState:UIControlStateNormal];
        }

        self.speakerButton.accessibilityValue = speakerStatusString;
        self.speakerButton.accessibilityHint = NSLocalizedString(@"Double tap to enable or disable the speaker", nil);
    });
}

- (void)setSpeakerButtonWithAirplayButton
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.speakerButton setImage:nil forState:UIControlStateNormal];
        self.speakerButton.accessibilityValue = NSLocalizedString(@"AirPlay button", nil);
        self.speakerButton.accessibilityHint = NSLocalizedString(@"Double tap to select different audio routes", nil);
        [self.speakerButton addSubview:self->_airplayView];
    });
}

- (IBAction)hangupButtonPressed:(id)sender
{
    [self hangupForAll:NO];
}

- (void)hangupForAll:(BOOL)allParticipants
{
    if (!_hangingUp) {
        _hangingUp = YES;
        // Dismiss possible notifications
        [[NSNotificationCenter defaultCenter] removeObserver:self];

        // Make sure we don't try to receive messages while hanging up
        if (_chatViewController) {
            [_chatViewController leaveChat];
            _chatViewController = nil;
        }
        
        [self.delegate callViewControllerWantsToBeDismissed:self];
        
        [_localVideoView.captureSession stopRunning];
        _localVideoView.captureSession = nil;
        [_localVideoView setHidden:YES];

        dispatch_async(dispatch_get_main_queue(), ^{
            for (NCPeerConnection *peerConnection in self->_peersInCall) {
                // Video renderers
                RTCMTLVideoView *videoRenderer = [self->_videoRenderersDict objectForKey:peerConnection.peerIdentifier];
                [self->_videoRenderersDict removeObjectForKey:peerConnection.peerIdentifier];

                // Screen renderers
                RTCMTLVideoView *screenRenderer = [self->_screenRenderersDict objectForKey:peerConnection.peerIdentifier];
                [self->_screenRenderersDict removeObjectForKey:peerConnection.peerIdentifier];

                [[WebRTCCommon shared] dispatch:^{
                    [[peerConnection.remoteStream.videoTracks firstObject] removeRenderer:videoRenderer];
                    [[peerConnection.remoteStream.videoTracks firstObject] removeRenderer:screenRenderer];
                }];
            }

            [self->_callDurationTimer invalidate];
        });
        
        if (_callController) {
            [_callController leaveCallForAll:allParticipants];
        } else {
            [self finishCall];
        }
    }
}

- (IBAction)videoCallButtonPressed:(id)sender
{
    [self showUpgradeToVideoCallDialog];
}

- (void)showUpgradeToVideoCallDialog
{
    UIAlertController *confirmDialog =
    [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Do you want to enable your camera?", nil)
                                        message:NSLocalizedString(@"If you enable your camera, this call will be interrupted for a few seconds.", nil)
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Enable", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self upgradeToVideoCall];
    }];
    [confirmDialog addAction:confirmAction];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [confirmDialog addAction:cancelAction];
    [self presentViewController:confirmDialog animated:YES completion:nil];
}

- (void)upgradeToVideoCall
{
    _videoCallUpgrade = YES;
    [self hangupForAll:NO];
}

- (IBAction)toggleChatButtonPressed:(id)sender
{
    [self toggleChatView];
}

- (CGFloat)getRightSideConstraintConstant
{
    CGFloat constant = 0;

    if (self.sideBarWidthConstraint.constant > 0) {
        // Take sidebar width into account
        constant += self.sideBarWidthConstraint.constant;

        // Add padding between the element and the sidebar
        constant += 8;
    }

    if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
        // On regular size classes, we also have a padding of 8 to the safe area
        constant += 8;
    }

    return constant;
}

- (void)setSideBarVisible:(BOOL)visible animated:(BOOL)animated withCompletion:(void (^ __nullable)(void))block
{
    [self.view layoutIfNeeded];

    if (visible) {
        [self.sideBarView setHidden:NO];
        [self.sideBarWidthConstraint setConstant:kSidebarWidth];
    } else {
        [self.sideBarWidthConstraint setConstant:0];
    }

    CGFloat rightConstraintConstant = [self getRightSideConstraintConstant];
    [self.topBarViewRightContraint setConstant:rightConstraintConstant];
    [self.screenshareViewRightContraint setConstant:rightConstraintConstant];
    [self.collectionViewRightConstraint setConstant:rightConstraintConstant];
    [self adjustTopBar];

    void (^animations)(void) = ^void() {
        [self.titleView layoutIfNeeded];
        [self.view layoutIfNeeded];
        [self adjustLocalVideoPositionFromOriginPosition:self.localVideoView.frame.origin];
    };

    void (^afterAnimations)(void) = ^void() {
        if (!visible) {
            [self.sideBarView setHidden:YES];
        }

        if (block) {
            block();
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.3f animations:^{
            animations();
        } completion:^(BOOL finished) {
            afterAnimations();
        }];
    } else {
        animations();
        afterAnimations();
    }
}

- (void)adjustChatLocation
{
    if (!_chatNavigationController) {
        return;
    }

    if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact && [_chatNavigationController.view isDescendantOfView:_sideBarView]) {
        // Chat is displayed in the sidebar, but needs to move to full screen

        // Remove chat from the sidebar and add to call view
        [_chatNavigationController.view removeFromSuperview];
        [self.view addSubview:_chatNavigationController.view];

        // Show the navigationbar in case of fullscreen and adjust the frame
        [_chatNavigationController setNavigationBarHidden:NO];
        _chatNavigationController.view.frame = self.view.bounds;

        // Finally hide the sidebar
        [self setSideBarVisible:NO animated:NO withCompletion:nil];
    } else if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular && [_chatNavigationController.view isDescendantOfView:self.view]) {
        // Chat is fullscreen, but should move to the sidebar

        // Remove chat from the call view and move it to the sidebar
        [_chatNavigationController.view removeFromSuperview];
        [self.sideBarView addSubview:_chatNavigationController.view];

        // Show the sidebar to have the correct bounds
        [self setSideBarVisible:YES animated:NO withCompletion:nil];

        CGRect sideBarViewBounds = self.sideBarView.bounds;
        _chatNavigationController.view.frame = CGRectMake(sideBarViewBounds.origin.x, sideBarViewBounds.origin.y, kSidebarWidth, sideBarViewBounds.size.height);

        // Don't show the navigation bar when we show the chat in the sidebar
        [_chatNavigationController setNavigationBarHidden:YES];
    }
}

- (void)showChat
{
    if (!_chatNavigationController) {
        // Create new chat controller
        TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
        NCRoom *room = [[NCRoomsManager sharedInstance] roomWithToken:_room.token forAccountId:activeAccount.accountId];
        _chatViewController = [[NCChatViewController alloc] initForRoom:room];
        _chatViewController.presentedInCall = YES;
        _chatNavigationController = [[UINavigationController alloc] initWithRootViewController:_chatViewController];
    }

    [self addChildViewController:_chatNavigationController];

    if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact) {
        // Show chat fullscreen
        [self.view addSubview:_chatNavigationController.view];

        _chatNavigationController.view.frame = self.view.bounds;
        _chatNavigationController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else {
        // Show chat in sidebar

        [self.sideBarView addSubview:_chatNavigationController.view];

        CGRect sideBarViewBounds = self.sideBarView.bounds;
        _chatNavigationController.view.frame = CGRectMake(sideBarViewBounds.origin.x, sideBarViewBounds.origin.y, kSidebarWidth, sideBarViewBounds.size.height);

        // Make sure the width does not change when collapsing the side bar (weird animation)
        _chatNavigationController.view.autoresizingMask = UIViewAutoresizingFlexibleHeight;

        [_chatNavigationController setNavigationBarHidden:YES];

        __weak typeof(self) weakSelf = self;

        [self setSideBarVisible:YES animated:YES withCompletion:^{
            __strong typeof(self) strongSelf = weakSelf;

            strongSelf->_chatNavigationController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }];
    }

    [_chatNavigationController didMoveToParentViewController:self];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    if (!_chatNavigationController) {
        return;
    }

    if (previousTraitCollection.horizontalSizeClass != self.traitCollection.horizontalSizeClass) {
        // Need to adjust the position of the chat, either sidebar -> fullscreen or fullscreen -> sidebar
        [self adjustChatLocation];
    }
}

- (void)toggleChatView
{
    if (!_chatNavigationController) {
        [self showChat];

        if (!_isAudioOnly) {
            [self.view bringSubviewToFront:_localVideoView];
        }

        [self removeTapGestureForDetailedView];
    } else {
        [self.view layoutIfNeeded];

        // Make sure we have a nice animation when closing the side bar and the chat is not squished
        _chatNavigationController.view.autoresizingMask = UIViewAutoresizingFlexibleHeight;

        __weak typeof(self) weakSelf = self;

        [self setSideBarVisible:NO animated:YES withCompletion:^{
            __strong typeof(self) strongSelf = weakSelf;

            [strongSelf->_chatViewController leaveChat];
            strongSelf->_chatViewController = nil;

            [strongSelf->_chatNavigationController willMoveToParentViewController:nil];
            [strongSelf->_chatNavigationController.view removeFromSuperview];
            [strongSelf->_chatNavigationController removeFromParentViewController];

            strongSelf->_chatNavigationController = nil;

            if (!strongSelf->_isAudioOnly && strongSelf->_callState == CallStateInCall) {
                [strongSelf addTapGestureForDetailedView];
                [strongSelf showDetailedViewWithTimer];
            }
        }];
    }
}

- (void)finishCall
{
    _callController = nil;
    if (_videoCallUpgrade) {
        _videoCallUpgrade = NO;
        [self.delegate callViewControllerWantsVideoCallUpgrade:self];
    } else {
        [self.delegate callViewControllerDidFinish:self];
    }
}

- (IBAction)lowerHandButtonPressed:(id)sender
{
    self->_isHandRaised = NO;
    [self->_callController raiseHand:NO];
    [self adjustTopBar];
}

- (IBAction)videoRecordingButtonPressed:(id)sender
{
    if (![_room canModerate]) {
        NSString *notificationText = NSLocalizedString(@"This call is being recorded", nil);
        [[JDStatusBarNotificationPresenter sharedPresenter] presentWithText:notificationText dismissAfterDelay:7.0 includedStyle:JDStatusBarNotificationIncludedStyleDark];
        
        return;
    }

    [self showStopRecordingConfirmationDialog];
}

- (void)showStopRecordingConfirmationDialog
{
    UIAlertController *confirmDialog =
    [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Stop recording", nil)
                                        message:NSLocalizedString(@"Do you want to stop the recording?", nil)
                                 preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *stopAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Stop", @"Action to 'Stop' a recording") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self->_callController stopRecording];
    }];
    [confirmDialog addAction:stopAction];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [confirmDialog addAction:cancelAction];

    [self presentViewController:confirmDialog animated:YES completion:nil];
}

#pragma mark - Call Reactions

- (void)addReaction:(NSString *)reaction fromUser:(NSString *)user
{
    CallReactionView *callReactionView = [[CallReactionView alloc] initWithFrame:CGRectZero];
    [callReactionView setReactionWithReaction:reaction actor:user];

    // Schedule when to show reaction
    CGFloat delayBetweenReactions = kReactionViewAnimationDuration / kMaxReactionsInScreen;
    CGFloat now = [[NSDate date] timeIntervalSince1970];

    if (_lastScheduledReaction < now) {
        delayBetweenReactions = (now - _lastScheduledReaction > delayBetweenReactions) ? 0 : delayBetweenReactions;
        _lastScheduledReaction = now;
    }

    _lastScheduledReaction += delayBetweenReactions;

    __weak typeof(self) weakSelf = self;
    CGFloat delay = _lastScheduledReaction - now;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void){
        [weakSelf showReaction:callReactionView];
    });
}

- (void)showReaction:(CallReactionView *)callReactionView
{
    CGSize callViewSize = self.view.bounds.size;
    CGSize callReactionSize = [callReactionView systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];

    CGFloat minLeftPosition = callViewSize.width * 0.05;
    CGFloat maxLeftPosition = callViewSize.width * 0.2;
    CGFloat randomLeftPosition = minLeftPosition + arc4random_uniform(maxLeftPosition - minLeftPosition + 1);

    CGFloat startPosition = callViewSize.height - self.view.safeAreaInsets.bottom - callReactionSize.height;
    CGFloat minTopPosition = startPosition / 2;
    CGFloat maxTopPosition = minTopPosition * 1.2;
    CGFloat randomTopPosition = minTopPosition + arc4random_uniform(maxTopPosition - minTopPosition + 1);

    if (callViewSize.width - callReactionSize.width < 0) {
        randomLeftPosition = minLeftPosition;
    }

    CGRect reactionInitialPosition = CGRectMake(randomLeftPosition,
                                                startPosition,
                                                callReactionSize.width,
                                                callReactionSize.height);

    callReactionView.frame = reactionInitialPosition;

    [self.view addSubview:callReactionView];
    [self.view bringSubviewToFront:callReactionView];

    [UIView animateWithDuration:2.0 animations:^{
        callReactionView.frame = CGRectMake(reactionInitialPosition.origin.x,
                                            randomTopPosition,
                                            reactionInitialPosition.size.width,
                                            reactionInitialPosition.size.height);
    }];

    [UIView animateWithDuration:1.0 delay:1.0 options:0 animations:^{
        callReactionView.alpha = 0;
    } completion:^(BOOL finished) {
        [callReactionView removeFromSuperview];
    }];
}

#pragma mark - CallParticipantViewCell delegate

- (void)cellWantsToPresentScreenSharing:(CallParticipantViewCell *)participantCell
{
    [self showScreenOfPeerIdentifier:participantCell.peerIdentifier];
}

- (void)cellWantsToChangeZoom:(CallParticipantViewCell *)participantCell showOriginalSize:(BOOL)showOriginalSize
{
    NCPeerConnection *peer = [self peerConnectionForPeerIdentifier:participantCell.peerIdentifier];
    
    if (peer) {
        [peer setShowRemoteVideoInOriginalSize:showOriginalSize];
    }
}

#pragma mark - UICollectionView Datasource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    [self setCallStateForPeersInCall];
    return [_peersInCall count];
}

- (void)updateParticipantCell:(CallParticipantViewCell *)cell withPeerConnection:(NCPeerConnection *)peerConnection
{
    BOOL isVideoDisabled = peerConnection.isRemoteVideoDisabled;

    if (_isAudioOnly || peerConnection.remoteStream == nil) {
        isVideoDisabled = YES;
    }
    
    [cell setVideoView:[_videoRenderersDict objectForKey:peerConnection.peerIdentifier]];

    [cell setDisplayName:peerConnection.peerName];
    [cell setAudioDisabled:peerConnection.isRemoteAudioDisabled];
    [cell setScreenShared:[_screenRenderersDict objectForKey:peerConnection.peerIdentifier]];
    [cell setVideoDisabled: isVideoDisabled];
    [cell setShowOriginalSize:peerConnection.showRemoteVideoInOriginalSize];
    [cell setRaiseHand:peerConnection.isHandRaised];
    [cell.peerNameLabel setAlpha:_isDetailedViewVisible ? 1.0 : 0.0];
    [cell.audioOffIndicator setAlpha:_isDetailedViewVisible ? 1.0 : 0.0];

    RTCIceConnectionState connectionState = peerConnection.isDummyPeer ?
    RTCIceConnectionStateConnected : peerConnection.peerConnection.iceConnectionState;
    [cell setConnectionState:connectionState];

    [[WebRTCCommon shared] dispatch:^{
        NSString *userId = [self->_callController getUserIdFromSessionId:peerConnection.peerId];

        dispatch_async(dispatch_get_main_queue(), ^{
            [cell setUserAvatar:userId withDisplayName:peerConnection.peerName];
        });
    }];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CallParticipantViewCell *cell = (CallParticipantViewCell *)[collectionView dequeueReusableCellWithReuseIdentifier:kCallParticipantCellIdentifier forIndexPath:indexPath];
    NCPeerConnection *peerConnection = [_peersInCall objectAtIndex:indexPath.row];
    cell.peerIdentifier = peerConnection.peerIdentifier;
    cell.actionsDelegate = self;
        
    return cell;
}

-(void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath
{
    CallParticipantViewCell *participantCell = (CallParticipantViewCell *)cell;
    NCPeerConnection *peerConnection = [_peersInCall objectAtIndex:indexPath.row];
    
    [self updateParticipantCell:participantCell withPeerConnection:peerConnection];
}

#pragma mark - Call Controller delegate

- (void)callControllerDidJoinCall:(NCCallController *)callController
{
    [self setCallStateForPeersInCall];

    // Show chat if it was visible before room switch
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^(void){
        if (self->_showChatAfterRoomSwitch && !self->_chatViewController) {
            self->_showChatAfterRoomSwitch = NO;
            [self toggleChatView];
        }
    });
}

- (void)callControllerDidFailedJoiningCall:(NCCallController *)callController statusCode:(NSNumber *)statusCode errorReason:(NSString *) errorReason
{
    [self presentJoinError:errorReason];
}

- (void)callControllerDidEndCall:(NCCallController *)callController
{
    [self finishCall];
}

- (void)callController:(NCCallController *)callController peerJoined:(NCPeerConnection *)peer
{
    // Always add a joined peer, even if the peer doesn't publish any streams (yet)
    [self addPeer:peer];
}

- (void)callController:(NCCallController *)callController peerLeft:(NCPeerConnection *)peer
{
    [self removePeer:peer];
}

- (void)callController:(NCCallController *)callController didCreateLocalVideoCapturer:(RTCCameraVideoCapturer *)videoCapturer
{
    _localVideoView.captureSession = videoCapturer.captureSession;
}

- (void)callController:(NCCallController *)callController userPermissionsChanged:(NSInteger)permissions
{
    [self setAudioMuteButtonEnabled:(permissions & NCPermissionCanPublishAudio)];
    [self setVideoDisableButtonEnabled:(permissions & NCPermissionCanPublishVideo)];
}

- (void)callController:(NCCallController *)callController didCreateLocalAudioTrack:(RTCAudioTrack *)audioTrack
{
    [self setAudioMuteButtonActive:audioTrack.isEnabled];
}

- (void)callController:(NCCallController *)callController didCreateLocalVideoTrack:(RTCVideoTrack *)videoTrack
{
    [self setLocalVideoViewHidden:!videoTrack.isEnabled];
    [self setVideoDisableButtonActive:videoTrack.isEnabled];
    
    // We set _userDisabledVideo = YES so the proximity sensor doesn't enable it.
    if (!videoTrack.isEnabled) {
        _userDisabledVideo = YES;
    }
}

- (void)callController:(NCCallController *)callController didAddStream:(RTCMediaStream *)remoteStream ofPeer:(NCPeerConnection *)remotePeer
{
    [[WebRTCCommon shared] assertQueue];

    dispatch_async(dispatch_get_main_queue(), ^{
        RTCMTLVideoView *renderView = [[RTCMTLVideoView alloc] initWithFrame:CGRectZero];

        [[WebRTCCommon shared] dispatch:^{
            RTCVideoTrack *remoteVideoTrack = [remotePeer.remoteStream.videoTracks firstObject];
            renderView.delegate = self;
            [remoteVideoTrack addRenderer:renderView];
        }];

        if ([remotePeer.roomType isEqualToString:kRoomTypeVideo]) {
            [self->_videoRenderersDict setObject:renderView forKey:remotePeer.peerIdentifier];
            NSIndexPath *indexPath = [self indexPathForPeerIdentifier:remotePeer.peerIdentifier];

            if (!indexPath) {
                // This is a new peer, add it

                [self addPeer:remotePeer];
            } else {
                // This peer already exists in the collection view, so we can just update its cell

                BOOL isVideoDisabled = (self->_isAudioOnly || remotePeer.isRemoteVideoDisabled);

                [self updatePeer:remotePeer block:^(CallParticipantViewCell *cell) {
                    [cell setVideoView:renderView];
                    [cell setVideoDisabled:isVideoDisabled];
                }];
            }
        } else if ([remotePeer.roomType isEqualToString:kRoomTypeScreen]) {
            [self->_screenRenderersDict setObject:renderView forKey:remotePeer.peerIdentifier];
            [self showScreenOfPeerIdentifier:remotePeer.peerIdentifier];
            [self updatePeer:remotePeer block:^(CallParticipantViewCell *cell) {
                [cell setScreenShared:YES];
            }];
        }
    });
}

- (void)callController:(NCCallController *)callController didRemoveStream:(RTCMediaStream *)remoteStream ofPeer:(NCPeerConnection *)remotePeer
{
    
}

- (void)callController:(NCCallController *)callController iceStatusChanged:(RTCIceConnectionState)state ofPeer:(NCPeerConnection *)peer
{
    if (state == RTCIceConnectionStateClosed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([peer.roomType isEqualToString:kRoomTypeVideo]) {
                [self removePeer:peer];
            } else if ([peer.roomType isEqualToString:kRoomTypeScreen]) {
                [self removeScreensharingOfPeer:peer];
            }
        });
    } else if ([peer.roomType isEqualToString:kRoomTypeVideo]) {
        [self updatePeer:peer block:^(CallParticipantViewCell *cell) {
            [cell setConnectionState:state];
        }];
    }
}

- (void)callController:(NCCallController *)callController didAddDataChannel:(RTCDataChannel *)dataChannel
{
}

- (void)callController:(NCCallController *)callController didReceiveDataChannelMessage:(NSString *)message fromPeer:(NCPeerConnection *)peer
{
    if ([message isEqualToString:@"audioOn"] || [message isEqualToString:@"audioOff"]) {
        [self updatePeer:peer block:^(CallParticipantViewCell *cell) {
            [cell setAudioDisabled:peer.isRemoteAudioDisabled];
        }];
    } else if ([message isEqualToString:@"videoOn"] || [message isEqualToString:@"videoOff"]) {
        if (!_isAudioOnly) {
            [self updatePeer:peer block:^(CallParticipantViewCell *cell) {
                [cell setVideoDisabled:peer.isRemoteVideoDisabled];
            }];
        }
    } else if ([message isEqualToString:@"speaking"] || [message isEqualToString:@"stoppedSpeaking"]) {
        if ([_peersInCall count] > 1) {
            [self updatePeer:peer block:^(CallParticipantViewCell *cell) {
                [cell setSpeaking:peer.isPeerSpeaking];
            }];
        }
    } else if ([message isEqualToString:@"raiseHand"]) {
        [self updatePeer:peer block:^(CallParticipantViewCell *cell) {
            [cell setRaiseHand:peer.isHandRaised];
        }];
    }
}

- (void)callController:(NCCallController *)callController didReceiveNick:(NSString *)nick fromPeer:(NCPeerConnection *)peer
{
    [self updatePeer:peer block:^(CallParticipantViewCell *cell) {
        [cell setDisplayName:nick];
    }];
}

- (void)callController:(NCCallController *)callController didReceiveUnshareScreenFromPeer:(NCPeerConnection *)peer
{
    [self removeScreensharingOfPeer:peer];
}

- (void)callController:(NCCallController *)callController didReceiveForceMuteActionForPeerId:(NSString *)peerId
{
    if ([peerId isEqualToString:callController.signalingSessionId]) {
        [self forceMuteAudio];
    } else {
        NSLog(@"Peer was force muted: %@", peerId);
    }
}

- (void)callController:(NCCallController *)callController didReceiveReaction:(NSString *)reaction fromPeer:(NCPeerConnection *)peer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (reaction.length == 0) {
            return;
        }
        NSString *user = peer.peerName;
        if (user.length == 0) {
            user = NSLocalizedString(@"Guest", nil);
        }

        [self addReaction:reaction fromUser:user];
    });
}

- (void)callControllerIsReconnectingCall:(NCCallController *)callController
{
    [self setCallState:CallStateReconnecting];
}

- (void)callControllerWantsToHangUpCall:(NCCallController *)callController
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hangupForAll:NO];
    });
}

- (void)callControllerDidChangeRecording:(NCCallController *)callController
{
    [self adjustTopBar];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *notificationText = NSLocalizedString(@"Call recording stopped", nil);

        if (self->_room.callRecording == NCCallRecordingStateVideoStarting || self->_room.callRecording == NCCallRecordingStateAudioStarting) {
            notificationText = NSLocalizedString(@"Call recording is starting", nil);
        } else if (self->_room.callRecording == NCCallRecordingStateVideoRunning || self->_room.callRecording == NCCallRecordingStateAudioRunning) {
            notificationText = NSLocalizedString(@"Call recording started", nil);
        } else if (self->_room.callRecording == NCCallRecordingStateFailed && self->_room.isUserOwnerOrModerator) {
            notificationText = NSLocalizedString(@"Call recording failed. Please contact your administrator", nil);
        }

        [[JDStatusBarNotificationPresenter sharedPresenter] presentWithText:notificationText dismissAfterDelay:7.0 includedStyle:JDStatusBarNotificationIncludedStyleDark];
    });
}

- (void)callController:(NCCallController *)callController isSwitchingToCall:(NSString *)token withAudioEnabled:(BOOL)audioEnabled andVideoEnabled:(BOOL)videoEnabled
{
    [self setCallState:CallStateSwitchingToAnotherRoom];

    // Close chat before switching to another room
    if (_chatViewController) {
        _showChatAfterRoomSwitch = YES;
        [self toggleChatView];
    }

    // Connect to new call
    TalkAccount *activeAccount = [[NCDatabaseManager sharedInstance] activeAccount];
    [[NCRoomsManager sharedInstance] updateRoom:token withCompletionBlock:^(NSDictionary *roomDict, NSError *error) {
        if (error) {
            NSLog(@"Error getting room to switch");
            return;
        }
        // Prepare rooms manager to switch to another room
        [[NCRoomsManager sharedInstance] prepareSwitchToAnotherRoomFromRoom:self->_room.token withCompletionBlock:^(NSError *error) {
            // Notify callkit about room switch
            [self.delegate callViewController:self wantsToSwitchCallFromCall:self->_room.token toRoom:token];
            // Assign new room as current room
            self->_room = [NCRoom roomWithDictionary:roomDict andAccountId:activeAccount.accountId];
            // Save current audio and video state
            self->_audioDisabledAtStart = !audioEnabled;
            self->_videoDisabledAtStart = !videoEnabled;
            // Forget current call controller
            self->_callController = nil;
            // Join new room
            [[NCRoomsManager sharedInstance] joinRoom:token forCall:YES];
        }];
    }];
}

#pragma mark - Screensharing

- (void)showScreenOfPeerIdentifier:(NSString *)peerIdentifier
{
    dispatch_async(dispatch_get_main_queue(), ^{
        RTCMTLVideoView *renderView = [self->_screenRenderersDict objectForKey:peerIdentifier];

        [self->_screensharingView replaceContentView:renderView];
        [self->_screensharingView bringSubviewToFront:self->_closeScreensharingButton];

        [UIView transitionWithView:self->_screensharingView duration:0.4
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{self->_screensharingView.hidden = NO;}
                        completion:nil];
    });

    // Enable/Disable detailed view with tap gesture
    // in voice only call when screensharing is enabled
    if (_isAudioOnly) {
        [self addTapGestureForDetailedView];
        [self showDetailedViewWithTimer];
    }
}

- (void)removeScreensharingOfPeer:(NCPeerConnection *)peer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        RTCMTLVideoView *screenRenderer = [self->_screenRenderersDict objectForKey:peer.peerIdentifier];
        [self->_screenRenderersDict removeObjectForKey:peer.peerIdentifier];
        [self updatePeer:peer block:^(CallParticipantViewCell *cell) {
            [cell setScreenShared:NO];
        }];

        if (self->_screensharingView.contentView == screenRenderer) {
            [self closeScreensharingButtonPressed:self];
        }

        [[WebRTCCommon shared] dispatch:^{
            [[peer.remoteStream.videoTracks firstObject] removeRenderer:screenRenderer];
        }];
    });
}

- (IBAction)closeScreensharingButtonPressed:(id)sender
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView transitionWithView:self->_screensharingView duration:0.4
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{self->_screensharingView.hidden = YES;}
                        completion:nil];
    });

    // Back to normal voice only UI
    if (_isAudioOnly) {
        [self invalidateDetailedViewTimer];
        [self showDetailedView];
        [self removeTapGestureForDetailedView];
    }
}

#pragma mark - GestureDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

#pragma mark - RTCVideoViewDelegate

- (void)videoView:(RTCMTLVideoView*)videoView didChangeVideoSize:(CGSize)size
{
    dispatch_async(dispatch_get_main_queue(), ^{
        for (RTCMTLVideoView *rendererView in [self->_videoRenderersDict allValues]) {
            if ([videoView isEqual:rendererView]) {
                rendererView.frame = CGRectMake(0, 0, size.width, size.height);
                NSArray *keys = [self->_videoRenderersDict allKeysForObject:videoView];
                if (keys.count) {
                    NSIndexPath *indexPath = [self indexPathForPeerIdentifier:keys[0]];
                    if (indexPath) {
                        CallParticipantViewCell *participantCell = (CallParticipantViewCell *) [self.collectionView cellForItemAtIndexPath:indexPath];
                        [participantCell setRemoteVideoSize:size];
                    }
                }
            }
        }
        for (RTCMTLVideoView *rendererView in [self->_screenRenderersDict allValues]) {
            if ([videoView isEqual:rendererView]) {
                rendererView.frame = CGRectMake(0, 0, size.width, size.height);
                if ([self.screensharingView.contentView isEqual:rendererView]) {
                    self->_screensharingSize = rendererView.frame.size;
                    [self->_screensharingView setContentViewSize:rendererView.frame.size];
                    [self->_screensharingView resizeContentView];
                }
            }
        }
    });
}

#pragma mark - Cell updates

- (NSIndexPath *)indexPathForPeerIdentifier:(NSString *)peerIdentifier
{
    NSIndexPath *indexPath = nil;
    for (int i = 0; i < _peersInCall.count; i ++) {
        NCPeerConnection *peer = [_peersInCall objectAtIndex:i];
        if ([peer.peerIdentifier isEqualToString:peerIdentifier]) {
            indexPath = [NSIndexPath indexPathForRow:i inSection:0];
        }
    }
    
    return indexPath;
}

- (void)updatePeer:(NCPeerConnection *)peer block:(UpdateCallParticipantViewCellBlock)block
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSIndexPath *indexPath = [self indexPathForPeerIdentifier:peer.peerIdentifier];
        if (indexPath) {
            CallParticipantViewCell *cell = (id)[self.collectionView cellForItemAtIndexPath:indexPath];
            block(cell);
        } else {
            // The participant might not be added at this point -> delay the update

            PendingCellUpdate *pendingUpdate = [[PendingCellUpdate alloc] init];
            pendingUpdate.peer = peer;
            pendingUpdate.block = block;

            [self->_pendingPeerUpdates addObject:pendingUpdate];
        }
    });
}

- (NCPeerConnection *)peerConnectionForPeerIdentifier:(NSString *)peerIdentifier {
    for (NCPeerConnection *peerConnection in self->_peersInCall) {
        if ([peerConnection.peerIdentifier isEqualToString:peerIdentifier]) {
            return peerConnection;
        }
    }
    
    return nil;
}

- (void)showPeersInfo
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *visibleCells = [self->_collectionView visibleCells];
        for (CallParticipantViewCell *cell in visibleCells) {
            [UIView animateWithDuration:0.3f animations:^{
                [cell.peerNameLabel setAlpha:1.0f];
                [cell.audioOffIndicator setAlpha:1.0f];
                [cell layoutIfNeeded];
            }];
        }
    });
}

- (void)hidePeersInfo
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *visibleCells = [self->_collectionView visibleCells];
        for (CallParticipantViewCell *cell in visibleCells) {
            [UIView animateWithDuration:0.3f animations:^{
                // Don't hide raise hand indicator, that should always be visible
                [cell.peerNameLabel setAlpha:0.0f];
                [cell.audioOffIndicator setAlpha:0.0f];
                [cell layoutIfNeeded];
            }];
        }
    });
}

- (void)addPeer:(NCPeerConnection *)peer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_peersInCall.count == 0) {
            // Don't delay adding the first peer

            [self->_peersInCall addObject:peer];
            NSIndexPath *insertionIndexPath = [NSIndexPath indexPathForRow:0 inSection:0];
            [self.collectionView insertItemsAtIndexPaths:@[insertionIndexPath]];
        } else {
            // Delay updating the collection view a bit to allow batch updating

            [self->_pendingPeerInserts addObject:peer];
            [self scheduleBatchCollectionViewUpdate];
        }
    });
}

- (void)removePeer:(NCPeerConnection *)peer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self->_pendingPeerInserts containsObject:peer]) {
            // The peer is a pending insert, but was removed before the batch update
            // In this case we can just remove the pending insert
            [self->_pendingPeerInserts removeObject:peer];
        } else {
            [self->_pendingPeerDeletions addObject:peer];
            [self scheduleBatchCollectionViewUpdate];
        }
    });
}

- (void)scheduleBatchCollectionViewUpdate
{
    // Make sure to call this only from the main queue

    if (self->_batchUpdateTimer == nil) {
        self->_batchUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(batchCollectionViewUpdate) userInfo:nil repeats:NO];
    }
}

- (void)batchCollectionViewUpdate
{
    self->_batchUpdateTimer = nil;

    if (_pendingPeerInserts.count == 0 && _pendingPeerDeletions.count == 0) {
        return;
    }

    [_collectionView performBatchUpdates:^{
        // Perform deletes before inserts according to apples docs
        NSMutableArray *indexPathsToDelete = [[NSMutableArray alloc] init];

        // Determine all indexPaths we want to delete and remove the renderers
        for (NCPeerConnection *peer in _pendingPeerDeletions) {
            // Video renderers
            RTCMTLVideoView *videoRenderer = [self->_videoRenderersDict objectForKey:peer.peerIdentifier];
            [self->_videoRenderersDict removeObjectForKey:peer.peerIdentifier];

            [[WebRTCCommon shared] dispatch:^{
                [[peer.remoteStream.videoTracks firstObject] removeRenderer:videoRenderer];
            }];

            // Screen renderers
            [self removeScreensharingOfPeer:peer];

            NSIndexPath *indexPath = [self indexPathForPeerIdentifier:peer.peerIdentifier];

            // Make sure we remove every index path only once
            if (indexPath && ![indexPathsToDelete containsObject:indexPath]) {
                [indexPathsToDelete addObject:indexPath];
            }
        }

        // Deletes should be done in descending order
        NSSortDescriptor *rowSortDescending = [[NSSortDescriptor alloc] initWithKey:@"row" ascending:NO];
        NSArray *indexPathsToDeleteSorted = [indexPathsToDelete sortedArrayUsingDescriptors:@[rowSortDescending]];

        for (NSIndexPath *indexPath in indexPathsToDeleteSorted) {
            [self->_peersInCall removeObjectAtIndex:indexPath.row];
            [_collectionView deleteItemsAtIndexPaths:@[indexPath]];
        }

        // Add all new peers
        for (NCPeerConnection *peer in _pendingPeerInserts) {
            NSIndexPath *indexPath = [self indexPathForPeerIdentifier:peer.peerIdentifier];
            if (!indexPath) {
                [self->_peersInCall addObject:peer];
                NSIndexPath *insertionIndexPath = [NSIndexPath indexPathForRow:self->_peersInCall.count - 1 inSection:0];
                [self.collectionView insertItemsAtIndexPaths:@[insertionIndexPath]];
            }
        }

        // Process pending updates
        for (PendingCellUpdate *pendingUpdate in _pendingPeerUpdates) {
            [self updatePeer:pendingUpdate.peer block:pendingUpdate.block];
        }

        _pendingPeerInserts = [[NSMutableArray alloc] init];
        _pendingPeerDeletions = [[NSMutableArray alloc] init];
        _pendingPeerUpdates = [[NSMutableArray alloc] init];
    } completion:^(BOOL finished) {

    }];
}

#pragma mark - NCChatTitleViewDelegate

- (void)chatTitleViewTapped:(NCChatTitleView *)titleView
{
    RoomInfoTableViewController *roomInfoVC = [[RoomInfoTableViewController alloc] initForRoom:_room];
    roomInfoVC.hideDestructiveActions = YES;

    roomInfoVC.modalPresentationStyle = UIModalPresentationPageSheet;
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:roomInfoVC];
    [self presentViewController:navController animated:YES completion:nil];
}


@end
