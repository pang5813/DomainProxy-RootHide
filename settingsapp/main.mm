#import <UIKit/UIKit.h>
#import <roothide.h>
#include <arpa/inet.h>

static NSString *ConfigurationPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/local.domainproxy.pac");
}

@interface ProxyController : UIViewController
@property(nonatomic, strong) UITextField *ipField;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UILabel *statusLabel;
@end

@implementation ProxyController
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}
- (UITextField *)field:(NSString *)placeholder keyboard:(UIKeyboardType)keyboard {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = keyboard;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    return field;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"域名代理";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"完成输入" style:UIBarButtonItemStylePlain target:self action:@selector(dismissKeyboard)];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
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
    [stack addArrangedSubview:[self label:@"HTTP 代理" style:UIFontTextStyleTitle1]];
    [stack addArrangedSubview:[self label:@"仅 ip138.com 及其子域名走代理，其他域名保持直连。" style:UIFontTextStyleBody]];
    [stack addArrangedSubview:[self label:@"代理 IPv4 地址" style:UIFontTextStyleHeadline]];
    self.ipField = [self field:@"例如 192.168.1.10" keyboard:UIKeyboardTypeDecimalPad];
    self.ipField.accessibilityLabel = @"代理 IPv4 地址";
    [stack addArrangedSubview:self.ipField];
    [stack addArrangedSubview:[self label:@"代理端口" style:UIFontTextStyleHeadline]];
    self.portField = [self field:@"例如 8080" keyboard:UIKeyboardTypeNumberPad];
    self.portField.accessibilityLabel = @"代理端口";
    [stack addArrangedSubview:self.portField];
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *buttonConfig = [UIButtonConfiguration filledButtonConfiguration];
    buttonConfig.title = @"保存代理配置";
    buttonConfig.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    save.configuration = buttonConfig;
    [save.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [save addTarget:self action:@selector(saveConfiguration) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:save];
    self.statusLabel = [self label:@"" style:UIFontTextStyleFootnote];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:[self label:@"使用步骤\n1. 填写 IP 和端口，点保存。\n2. 在 RootHide 中为目标 App 开启插件注入。\n3. 彻底退出并重新打开目标 App。\n\n清空 IP 后保存可关闭域名代理。IPv6 拦截仍生效；关闭目标 App 的插件注入并重启该 App，可恢复其原有网络行为。" style:UIFontTextStyleBody]];
    UILabel *note = [self label:@"支持无认证的 HTTP 上游。HTTPS 通过 CONNECT 转发。当前是实验版本，IPv6 拦截和域名代理仅覆盖已注入且兼容的应用进程，未经过真机验证。" style:UIFontTextStyleFootnote];
    note.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:note];
    [self loadConfiguration];
}
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (NSString *)capture:(NSString *)pattern in:(NSString *)text {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}
- (void)loadConfiguration {
    NSString *source = [NSString stringWithContentsOfFile:ConfigurationPath() encoding:NSUTF8StringEncoding error:nil];
    if (!source) source = [NSString stringWithContentsOfFile:jbroot(@"/Library/DomainProxy/proxy.pac") encoding:NSUTF8StringEncoding error:nil];
    self.ipField.text = [self capture:@"var PROXY_IP = \"([^\"]*)\";" in:source ?: @""] ?: @"";
    self.portField.text = [self capture:@"var PROXY_PORT = ([0-9]+);" in:source ?: @""] ?: @"8080";
    self.statusLabel.text = self.ipField.text.length ? @"已读取保存的配置，连接状态需在目标 App 中验证。" : @"尚未配置代理。";
}
- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法保存" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)saveConfiguration {
    [self dismissKeyboard];
    NSString *ip = [self.ipField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *portText = [self.portField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    struct in_addr address;
    if (ip.length && inet_pton(AF_INET, ip.UTF8String, &address) != 1) {
        [self showError:@"请输入有效的 IPv4 地址，例如 192.168.1.10。"];
        return;
    }
    NSInteger port = portText.integerValue;
    NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    if (portText.length == 0 || [portText rangeOfCharacterFromSet:nonDigits].location != NSNotFound || port < 1 || port > 65535) {
        [self showError:@"端口必须是 1 到 65535 之间的整数。"];
        return;
    }
    NSString *templatePath = [NSBundle.mainBundle pathForResource:@"proxy" ofType:@"pac"];
    NSString *source = templatePath ? [NSString stringWithContentsOfFile:templatePath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!source || ![source containsString:@"var PROXY_IP = \"\";"] || ![source containsString:@"var PROXY_PORT = 8080;"]) {
        [self showError:@"安装包内的代理规则缺失，请重新安装此版本。"];
        return;
    }
    source = [source stringByReplacingOccurrencesOfString:@"var PROXY_IP = \"\";" withString:[NSString stringWithFormat:@"var PROXY_IP = \"%@\";", ip]];
    source = [source stringByReplacingOccurrencesOfString:@"var PROXY_PORT = 8080;" withString:[NSString stringWithFormat:@"var PROXY_PORT = %ld;", (long)port]];
    NSString *path = ConfigurationPath();
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error] ||
        ![NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:&error]) {
        [self showError:[NSString stringWithFormat:@"配置写入失败：%@", error.localizedDescription ?: @"未知错误"]];
        return;
    }
    self.ipField.text = ip;
    self.portField.text = [NSString stringWithFormat:@"%ld", (long)port];
    self.statusLabel.text = ip.length ? @"已保存。请彻底退出并重开目标 App；保存成功不代表代理连接成功。" : @"已保存为直连。请重启目标 App，IPv6 拦截仍然生效。";
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.statusLabel.text);
}
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
