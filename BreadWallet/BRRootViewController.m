//
//  BRRootViewController.m
//  BreadWallet
//
//  Created by Aaron Voisine on 9/15/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "BRRootViewController.h"
#import "BRReceiveViewController.h"
#import "BRSendViewController.h"
#import "BRPeerManager.h"
#import "BRWalletManager.h"
#import "BRWallet.h"
#import "Reachability.h"

@interface BRRootViewController ()

@property (nonatomic, strong) IBOutlet UIProgressView *progress, *pulse;
@property (nonatomic, strong) IBOutlet UIView *errorBar;
@property (nonatomic, strong) IBOutlet UIGestureRecognizer *navBarTap;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *wallpaperXLeft;
@property (nonatomic, assign) BOOL appeared;
@property (nonatomic, strong) Reachability *reachability;
@property (nonatomic, strong) id urlObserver, fileObserver, activeObserver, balanceObserver, reachabilityObserver;
@property (nonatomic, strong) id syncStartedObserver, syncFinishedObserver, syncFailedObserver;

@end

@implementation BRRootViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view.

    self.receiveViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"ReceiveViewController"];
    self.sendViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"SendViewController"];
    self.pageViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"PageViewController"];

    self.pageViewController.dataSource = self;
    [self.pageViewController setViewControllers:@[self.sendViewController]
     direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
    self.pageViewController.view.frame = self.view.bounds;
    [self addChildViewController:self.pageViewController];
    [self.view addSubview:self.pageViewController.view];
    [self.pageViewController didMoveToParentViewController:self];

    for (UIView *view in self.pageViewController.view.subviews) {
        if (! [view isKindOfClass:[UIScrollView class]]) continue;
        [(UIScrollView *)view setDelegate:self];
        [(UIScrollView *)view setDelaysContentTouches:NO]; // this allows buttons to respond more quickly
        break;
    }

    BRWalletManager *m = [BRWalletManager sharedInstance];

    self.urlObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRURLNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            [self.pageViewController setViewControllers:@[self.sendViewController]
             direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
            self.wallpaperXLeft.constant = 0;
            if (m.wallet) [self.navigationController dismissViewControllerAnimated:NO completion:nil];
        }];

    self.fileObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRFileNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            [self.pageViewController setViewControllers:@[self.sendViewController]
             direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
            self.wallpaperXLeft.constant = 0;
            if (m.wallet) [self.navigationController dismissViewControllerAnimated:NO completion:nil];
        }];

    self.activeObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            if (self.appeared) [[BRPeerManager sharedInstance] connect];
        }];

    self.reachabilityObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:kReachabilityChangedNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            if (self.appeared && self.reachability.currentReachabilityStatus != NotReachable) {
                [[BRPeerManager sharedInstance] connect];
            }
            else if (self.appeared && self.reachability.currentReachabilityStatus == NotReachable) {
                [self showErrorBar];
            }
        }];

    self.balanceObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRWalletBalanceChangedNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            if ([[BRPeerManager sharedInstance] syncProgress] < 1.0) return; // wait for sync before updating balance

            self.navigationItem.title = [NSString stringWithFormat:@"%@ (%@)", [m stringForAmount:m.wallet.balance],
                                         [m localCurrencyStringForAmount:m.wallet.balance]];

            // update receive qr code if it's not on screen
            if (self.pageViewController.viewControllers.lastObject != self.receiveViewController) {
                [self.receiveViewController viewWillAppear:NO];
            }
        }];

    self.syncStartedObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncStartedNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            if (self.reachability.currentReachabilityStatus != NotReachable) [self hideErrorBar];
            if (m.wallet.balance == 0) self.navigationItem.title = @"syncing...";
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            self.progress.hidden = self.pulse.hidden = NO;

            [UIView animateWithDuration:0.2 animations:^{
                self.progress.alpha = 1.0;
            }];

            [self updateProgress];
            [self performSelector:@selector(startPulse) withObject:nil afterDelay:1.0];
        }];
    
    self.syncFinishedObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFinishedNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            self.navigationItem.title = [NSString stringWithFormat:@"%@ (%@)", [m stringForAmount:m.wallet.balance],
                                         [m localCurrencyStringForAmount:m.wallet.balance]];
            [UIApplication sharedApplication].idleTimerDisabled = NO;

            if (self.progress.alpha > 0.5) {
                [self.progress setProgress:1.0 animated:YES];
                [self.pulse setProgress:1.0 animated:YES];

                [UIView animateWithDuration:0.2 animations:^{
                    self.progress.alpha = self.pulse.alpha = 0.0;
                } completion:^(BOOL finished) {
                    self.progress.hidden = self.pulse.hidden = YES;
                    self.progress.progress = self.pulse.progress = 0.0;
                }];
            }
        }];
    
    self.syncFailedObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFailedNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            self.navigationItem.title = [NSString stringWithFormat:@"%@ (%@)", [m stringForAmount:m.wallet.balance],
                                         [m localCurrencyStringForAmount:m.wallet.balance]];
            [UIApplication sharedApplication].idleTimerDisabled = NO;
            self.progress.hidden = self.pulse.hidden = YES;
            self.progress.progress = self.pulse.progress = 0.0;
            [self showErrorBar];
        }];
    
    self.reachability = [Reachability reachabilityForInternetConnection];
    [self.reachability startNotifier];

    self.navigationItem.title = [NSString stringWithFormat:@"%@ (%@)", [m stringForAmount:m.wallet.balance],
                                 [m localCurrencyStringForAmount:m.wallet.balance]];

#if BITCOIN_TESTNET
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, self.view.frame.size.height - 51,
                                                               self.view.frame.size.width, 21)];

    label.font = [UIFont fontWithName:@"HelveticaNeue-Light" size:13.0];
    label.textColor = [UIColor redColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"testnet";
    [self.view addSubview:label];
#endif
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    if (! [[BRWalletManager sharedInstance] wallet]) {
        if (! [[UIApplication sharedApplication] isProtectedDataAvailable]) return;

        UINavigationController *c = [self.storyboard instantiateViewControllerWithIdentifier:@"NewWalletNav"];

        [self.navigationController presentViewController:c animated:NO completion:nil];
        return;
    }

    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault];
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationFade];
    [[BRPeerManager sharedInstance] connect];
}

- (void)viewDidAppear:(BOOL)animated
{
    if (! self.appeared) {
        self.appeared = YES;
        
        if ([[[BRWalletManager sharedInstance] wallet] balance] == 0) {
            [self.pageViewController setViewControllers:@[self.receiveViewController]
             direction:UIPageViewControllerNavigationDirectionForward animated:YES completion:nil];
        }
    }

    if (self.reachability.currentReachabilityStatus == NotReachable) [self showErrorBar];

    [super viewDidAppear:animated];
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self.reachability stopNotifier];

    if (self.urlObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.urlObserver];
    if (self.fileObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.fileObserver];
    if (self.activeObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.activeObserver];
    if (self.reachabilityObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.reachabilityObserver];
    if (self.balanceObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.balanceObserver];
    if (self.syncStartedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncStartedObserver];
    if (self.syncFinishedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFinishedObserver];
    if (self.syncFailedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFailedObserver];
}

- (void)updateProgress
{
    double progress = [[BRPeerManager sharedInstance] syncProgress];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateProgress) object:nil];

    if (progress > DBL_EPSILON && progress != self.progress.progress) {
        if (progress < self.pulse.progress || self.pulse.progress == self.progress.progress) {
            [self.pulse setProgress:progress animated:(progress > self.progress.progress)];
        }

        [self.progress setProgress:progress animated:(progress > self.progress.progress)];
    }

    if (progress < 1.0) [self performSelector:@selector(updateProgress) withObject:nil afterDelay:0.2];
}

- (void)startPulse
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pulse) object:nil];
    if (self.progress.hidden) return;

    [self.pulse setProgress:self.progress.progress animated:(self.progress.progress > self.pulse.progress)];

    [UIView animateWithDuration:1.5 delay:1.0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.pulse.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.pulse.alpha = 1.0;
        self.pulse.progress = 0;
        [self performSelector:@selector(startPulse) withObject:nil afterDelay:0.0];
    }];
}

- (void)showErrorBar {
    if (self.navigationItem.prompt != nil) return;
    self.navigationItem.prompt = @"";
    self.errorBar.hidden = NO;
    self.errorBar.alpha = 0.0;
    
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration delay:0.0
     options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.errorBar.alpha = 1.0;
    } completion:nil];

    self.navBarTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(connect:)];
    [self.navigationController.navigationBar addGestureRecognizer:self.navBarTap];
}

- (void)hideErrorBar {
    if (self.navigationItem.prompt == nil) return;
    self.navigationItem.prompt = nil;
    [self.navigationController.navigationBar removeGestureRecognizer:self.navBarTap];
    self.navBarTap = nil;
    
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration delay:0.0
     options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.errorBar.alpha = 0.0;
    } completion:^(BOOL finished) {
        if (self.navigationItem.prompt == nil) self.errorBar.hidden = YES;
    }];
}

- (IBAction)connect:(id)sender
{
    if (! sender && [self.reachability currentReachabilityStatus] == NotReachable) return;

    [[BRPeerManager sharedInstance] connect];
}

#pragma mark UIPageViewControllerDataSource

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController
viewControllerBeforeViewController:(UIViewController *)viewController
{
    return (viewController == self.receiveViewController) ? self.sendViewController : nil;
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController
viewControllerAfterViewController:(UIViewController *)viewController
{
    return (viewController == self.sendViewController) ? self.receiveViewController : nil;
}

- (NSInteger)presentationCountForPageViewController:(UIPageViewController *)pageViewController
{
    return 2;
}

- (NSInteger)presentationIndexForPageViewController:(UIPageViewController *)pageViewController
{
    return (pageViewController.viewControllers.lastObject == self.receiveViewController) ? 1 : 0;
}

#pragma mark UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    self.wallpaperXLeft.constant = (scrollView.contentOffset.x +
                                   (scrollView.contentInset.left < 0 ? scrollView.contentInset.left : 0))*PARALAX_RATIO;
}

@end