//
//  GroupedChatMessageTableViewCell.h
//  VideoCalls
//
//  Created by Ivan Sein on 02.05.18.
//  Copyright © 2018 struktur AG. All rights reserved.
//

#import <UIKit/UIKit.h>

static CGFloat kGroupedChatMessageCellMinimumHeight = 30.0;

static NSString *GroupedChatMessageCellIdentifier = @"GroupedChatMessageCellIdentifier";

@interface GroupedChatMessageTableViewCell : UITableViewCell

@property (nonatomic, strong) UILabel *bodyLabel;

@property (nonatomic, strong) NSIndexPath *indexPath;
@property (nonatomic) BOOL usedForMessage;

+ (CGFloat)defaultFontSize;

@end
