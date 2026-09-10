using System.Globalization;
using PasswallReceiver.Core;

namespace PasswallReceiver;

internal sealed class ReceiverStrings(ReceiverLanguage preference)
{
    private static readonly IReadOnlyDictionary<string, string> Chinese =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Passwall Receiver"] = "Passwall 接收端",
            ["Transfer"] = "传输",
            ["Devices"] = "设备",
            ["Settings"] = "设置",
            ["Logs / About"] = "日志 / 关于",
            ["Receive to"] = "接收到",
            ["Choose receive folder"] = "选择接收文件夹",
            ["Send files"] = "发送文件",
            ["Send folder"] = "发送文件夹",
            ["Clear history"] = "清除历史",
            ["No transfers yet"] = "暂无传输记录",
            ["Name"] = "名称",
            ["Direction"] = "方向",
            ["Status"] = "状态",
            ["Size"] = "大小",
            ["Progress"] = "进度",
            ["Started"] = "开始时间",
            ["Send"] = "发送",
            ["Receive"] = "接收",
            ["Queued"] = "已排队",
            ["Awaiting approval"] = "等待确认",
            ["Transferring"] = "传输中",
            ["Verifying"] = "校验中",
            ["Completed"] = "已完成",
            ["Rejected"] = "已拒绝",
            ["Canceled"] = "已取消",
            ["Failed"] = "失败",
            ["Cancel"] = "取消",
            ["Retry"] = "重试",
            ["Show in Explorer"] = "在资源管理器中显示",
            ["Mac controller"] = "Mac 控制端",
            ["Connected securely"] = "已安全连接",
            ["Not connected"] = "未连接",
            ["Trusted pairing is stored in Windows Credential Manager."] = "可信配对保存在 Windows 凭据管理器中。",
            ["Language"] = "语言",
            ["Follow system"] = "跟随系统",
            ["English"] = "英语",
            ["Simplified Chinese"] = "简体中文",
            ["Open logs"] = "打开日志",
            ["Log file"] = "日志文件",
            ["Local-network input, clipboard, and file sharing."] = "局域网输入、剪贴板与文件共享。",
            ["Protocol"] = "协议",
            ["Close keeps Passwall running in the tray."] = "关闭窗口后 Passwall 会继续在托盘运行。",
            ["Incoming files"] = "收到文件",
            ["From Mac"] = "来自 Mac",
            ["items"] = "项",
            ["Save to"] = "保存到",
            ["Use as default receive folder"] = "设为默认接收文件夹",
            ["Reject"] = "拒绝",
            ["Accept"] = "接受",
            ["More"] = "更多",
            ["Open Transfer Center"] = "打开传输中心",
            ["Restart Receiver"] = "重启接收端",
            ["Open Logs"] = "打开日志",
            ["Exit Passwall Receiver"] = "退出 Passwall 接收端",
            ["Starting"] = "正在启动",
            ["Running"] = "运行中",
            ["Stopped"] = "已停止",
            ["Restarting"] = "正在重启",
            ["Stopping"] = "正在停止",
            ["Active transfers will be canceled. Exit Passwall Receiver?"] = "活动传输将被取消。确定退出 Passwall 接收端吗？",
            ["Files are waiting for your approval."] = "有文件等待你的确认。",
            ["File selection failed"] = "文件选择失败",
            ["The selected files could not be prepared."] = "无法准备所选文件。",
            ["This transfer can no longer be approved."] = "该传输已无法批准。",
            ["Receiver error"] = "接收端错误"
        };

    private bool UseChinese => preference == ReceiverLanguage.SimplifiedChinese ||
        preference == ReceiverLanguage.System &&
        CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);

    public string this[string english] =>
        UseChinese && Chinese.TryGetValue(english, out var translation) ? translation : english;
}
