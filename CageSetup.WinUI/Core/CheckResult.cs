namespace CageSetup.WinUI.Core
{
    public enum CheckStatus
    {
        Ok,
        Warn,
        Error,
        Unknown
    }

    public sealed class CheckResult
    {
        public string Title { get; }
        public string Value { get; }
        public string Detail { get; }
        public CheckStatus Status { get; }

        public CheckResult(string title, string value, string detail, CheckStatus status)
        {
            Title = title;
            Value = value;
            Detail = detail;
            Status = status;
        }
    }
}
