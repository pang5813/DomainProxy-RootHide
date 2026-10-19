#import <UIKit/UIKit.h>
#import <roothide.h>
#include <arpa/inet.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
extern char **environ;

@interface ProxyController : UIViewController
@property(nonatomic, strong) UITextField *ipField;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) NSMutableArray<UIButton *> *buttons;
@property(nonatomic) BOOL busy;
@end

@implementation ProxyController
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [UILabel new];
    label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}
- (UITextField *)field:(NSString *)hint keyboard:(UIKeyboardType)keyboard {
    UITextField *field = [UITextField new];
    field.placeholder = hint; field.keyboardType = keyboard;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return field;
}
- (UIButton *)button:(NSString *)title action:(SEL)action primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = primary ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration tintedButtonConfiguration];
    config.title = title; config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.configuration = config;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.buttons addObject:button];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"全局域名代理";
    self.buttons = [NSMutableArray new];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成输入" style:UIBarButtonItemStylePlain target:self action:@selector(dismissKeyboard)];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    [stack addArrangedSubview:[self label:@"HTTP 上游代理" style:UIFontTextStyleTitle1]];
    [stack addArrangedSubview:[self label:@"启动全局隧道后，仅 ip138.com 及其子域名走代理，其余 IPv4 流量直连。隧道内 IPv6 流量被拦截。" style:UIFontTextStyleBody]];
    [stack addArrangedSubview:[self label:@"代理 IPv4 地址" style:UIFontTextStyleHeadline]];
    self.ipField = [self field:@"例如 192.168.1.10" keyboard:UIKeyboardTypeDecimalPad];
    self.ipField.accessibilityLabel = @"代理 IPv4 地址";
    [stack addArrangedSubview:self.ipField];
    [stack addArrangedSubview:[self label:@"代理端口" style:UIFontTextStyleHeadline]];
    self.portField = [self field:@"例如 8080" keyboard:UIKeyboardTypeNumberPad];
    self.portField.accessibilityLabel = @"代理端口";
    [stack addArrangedSubview:self.portField];
    [stack addArrangedSubview:[self button:@"保存并启动全局代理" action:@selector(start) primary:YES]];
    [stack addArrangedSubview:[self button:@"停止全局代理" action:@selector(stop) primary:NO]];
    [stack addArrangedSubview:[self button:@"刷新服务状态" action:@selector(refresh) primary:NO]];
    [stack addArrangedSubview:[self button:@"查看运行日志" action:@selector(log) primary:NO]];
    self.statusLabel = [self label:@"正在读取服务状态…" style:UIFontTextStyleFootnote];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.statusLabel];
    UILabel *note = [self label:@"适用于 iOS 16.1 Dopamine RootHide，无需为目标 App 开启注入。支持无认证 HTTP 上游；目标域名的 UDP 请求被拒绝。\n\n首次启动请先关闭其他 VPN。启动后会检查 DNS 和隧道双向收发，不通过则自动停止，避免持续断网。\n\n请验证出口 IP、非目标网站和 IPv6。网络切换异常时，请停止后重新启动。\n\n实验版本，尚未完成真机验证。启动自检不能保证所有 App 都被接管。停止服务后恢复系统网络，不提供断线锁网。" style:UIFontTextStyleFootnote];
    note.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:note];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.ipField.text = [defaults stringForKey:@"ProxyIP"] ?: @"";
    self.portField.text = [defaults stringForKey:@"ProxyPort"] ?: @"8080";
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self refresh]; }
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (void)run:(NSString *)command arguments:(NSArray<NSString *> *)arguments {
    if (self.busy) return;
    self.busy = YES;
    for (UIButton *button in self.buttons) button.enabled = NO;
    self.statusLabel.text = @"正在处理…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *helper = jbroot(@"/usr/bin/domainproxyctl");
        NSArray<NSString *> *all = [@[helper, command] arrayByAddingObjectsFromArray:arguments];
        char **args = (char **)calloc(all.count + 1, sizeof(char *));
        for (NSUInteger i = 0; i < all.count; ++i) args[i] = strdup(all[i].UTF8String);
        int pipes[2];
        NSMutableData *output = [NSMutableData new];
        int result = pipe(pipes);
        if (result == 0) {
            posix_spawn_file_actions_t actions;
            posix_spawn_file_actions_init(&actions);
            posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
            posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
            posix_spawn_file_actions_addclose(&actions, pipes[0]);
            posix_spawn_file_actions_addclose(&actions, pipes[1]);
            pid_t pid = 0;
            result = posix_spawn(&pid, helper.fileSystemRepresentation, &actions, NULL, args, environ);
            posix_spawn_file_actions_destroy(&actions);
            close(pipes[1]);
            if (result == 0) {
                char buffer[4096]; ssize_t size;
                while ((size = read(pipes[0], buffer, sizeof(buffer))) > 0) [output appendBytes:buffer length:size];
                int status; waitpid(pid, &status, 0);
            }
            close(pipes[0]);
        } else { result = errno; }
        for (NSUInteger i = 0; i < all.count; ++i) free(args[i]);
        free(args);
        NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:output options:0 error:nil];
        NSString *message = reply[@"message"];
        if (!message) message = result ? [NSString stringWithFormat:@"无法运行服务控制器：%s。请确认越狱已启用并重新安装。", strerror(result)] : [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        if (!message.length) message = @"服务控制器没有返回结果，请重新安装并确认越狱状态。";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            for (UIButton *button in self.buttons) button.enabled = YES;
            self.statusLabel.text = message;
            if ([command isEqualToString:@"log"]) {
                UIViewController *viewer = [UIViewController new];
                viewer.title = @"运行日志";
                UITextView *text = [[UITextView alloc] initWithFrame:CGRectZero];
                text.editable = NO; text.text = message;
                text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
                text.backgroundColor = UIColor.systemBackgroundColor;
                viewer.view = text;
                [self.navigationController pushViewController:viewer animated:YES];
            }
        });
    });
}
- (void)start {
    [self dismissKeyboard];
    NSString *ip = [self.ipField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *port = [self.portField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    struct in_addr address;
    NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    if (inet_pton(AF_INET, ip.UTF8String, &address) != 1 || !port.length || [port rangeOfCharacterFromSet:nonDigits].location != NSNotFound || port.integerValue < 1 || port.integerValue > 65535) {
        self.statusLabel.text = @"请输入有效的 IPv4 地址和 1 到 65535 之间的端口。";
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:ip forKey:@"ProxyIP"];
    [NSUserDefaults.standardUserDefaults setObject:port forKey:@"ProxyPort"];
    [self run:@"start" arguments:@[ip, port]];
}
- (void)stop { [self run:@"stop" arguments:@[]]; }
- (void)refresh { [self run:@"status" arguments:@[]]; }
- (void)log { [self run:@"log" arguments:@[]]; }
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[ProxyController new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
