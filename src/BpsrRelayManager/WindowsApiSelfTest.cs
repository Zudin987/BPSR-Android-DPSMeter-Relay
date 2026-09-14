using System;
using System.Collections.Generic;

namespace BpsrRelayManager
{
    internal static class WindowsApiSelfTest
    {
        public static void Run()
        {
            List<LanAddress> addresses = WindowsIntegration.GetLanAddresses();
            if (addresses.Count == 0)
            {
                throw new InvalidOperationException("Windows API self-test could not find an active non-loopback IPv4 adapter.");
            }

            string category = WindowsIntegration.GetNetworkCategory(addresses[0].AdapterId);
            if (string.Equals(category, "Unknown", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Network List Manager COM could not resolve the active adapter category.");
            }

            Type policyType = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
            if (policyType == null)
            {
                throw new InvalidOperationException("Windows Firewall COM policy object is unavailable.");
            }

            dynamic policy = Activator.CreateInstance(policyType);
            int currentProfiles = (int)policy.CurrentProfileTypes;
            if (currentProfiles <= 0)
            {
                throw new InvalidOperationException("Windows Firewall COM returned no active profile types.");
            }
        }
    }
}
