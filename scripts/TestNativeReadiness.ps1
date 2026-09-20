param([Parameter(Mandatory = $true)][string]$ManagerExe)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $ManagerExe).Path
$assembly = [System.Reflection.Assembly]::LoadFrom($exe)
$type = $assembly.GetType('BpsrRelayManager.RelayEngine', $true)
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Reflection;
public static class NativeReadinessHarness
{
    private static readonly BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    public static object Create(Type type, string root)
    {
        var ctor = type.GetConstructor(Flags, null, new Type[] { typeof(string), typeof(Action<string>) }, null);
        if (ctor == null) throw new InvalidOperationException("RelayEngine constructor changed.");
        return ctor.Invoke(new object[] { root, null });
    }
    public static void Invoke(Type type, object engine, string method, string argument)
    {
        var info = type.GetMethod(method, Flags);
        if (info == null) throw new InvalidOperationException("Missing native method " + method);
        info.Invoke(engine, info.GetParameters().Length == 0 ? null : new object[] { argument });
    }
    public static bool Confirmed(Type type, object engine)
    {
        return (bool)type.GetMethod("PhoneProfileConfirmed", Flags).Invoke(engine, null);
    }
    public static string PhonePreflight(Type type, object engine)
    {
        var items = (IEnumerable)type.GetMethod("GetPreflightChecks", Flags).Invoke(engine, new object[] { "192.0.2.10" });
        foreach (object item in items)
        {
            Type t = item.GetType();
            if ((string)t.GetField("Name", Flags).GetValue(item) == "Phone import")
                return (string)t.GetField("State", Flags).GetValue(item);
        }
        throw new InvalidOperationException("Phone import readiness check is absent.");
    }
}
'@
$temp = Join-Path ([IO.Path]::GetTempPath()) ('bpsr-readiness-' + [Guid]::NewGuid().ToString('N'))
try {
    $engine = [NativeReadinessHarness]::Create($type, [string]$temp)
    $meta = Join-Path $temp 'output\profile-meta.json'
    $state = Join-Path $temp '.runtime\phone-profile-state.json'
    $profile = Join-Path $temp 'output\android-bpsr-relay.json'
    [IO.File]::WriteAllText($profile, '{}')
    [IO.File]::WriteAllText($meta, '{"profileId":"audit-profile-one","pcIp":"192.0.2.10"}')
    if ([NativeReadinessHarness]::Confirmed($type, $engine)) { throw 'Fresh phone profile incorrectly confirmed.' }
    if ([NativeReadinessHarness]::PhonePreflight($type, $engine) -ne 'FAIL') { throw 'Run Check incorrectly reports an unimported phone as ready.' }
    [NativeReadinessHarness]::Invoke($type, $engine, 'MarkPhoneProfileDownloaded', $null)
    if ([NativeReadinessHarness]::Confirmed($type, $engine)) { throw 'Downloading a profile incorrectly confirmed its import.' }
    [NativeReadinessHarness]::Invoke($type, $engine, 'MarkPhoneProfileConfirmed', 'user-confirmed-manual-import')
    if (-not [NativeReadinessHarness]::Confirmed($type, $engine)) { throw 'Manual import confirmation was lost.' }
    if ([NativeReadinessHarness]::PhonePreflight($type, $engine) -ne 'OK') { throw 'Run Check failed to recognize confirmed phone setup.' }
    [NativeReadinessHarness]::Invoke($type, $engine, 'MarkPhoneProfileDownloaded', $null)
    if (-not [NativeReadinessHarness]::Confirmed($type, $engine)) { throw 'A subsequent SFA download erased explicit import confirmation.' }
    [IO.File]::WriteAllText($meta, '{"profileId":"audit-profile-two","pcIp":"192.0.2.10"}')
    if ([NativeReadinessHarness]::Confirmed($type, $engine)) { throw 'Changed profile retained stale import confirmation.' }
    if ([NativeReadinessHarness]::PhonePreflight($type, $engine) -ne 'FAIL') { throw 'Changed profile incorrectly reported ready.' }
    Write-Host 'NATIVE READINESS PASS: initial FAIL, downloaded FAIL, manual confirmation OK, repeated download preserved, identity change invalidated.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
