# Settings for join-network.ps1, install.ps1, uninstall.ps1 and the scripts.
# Nothing here is machine-specific: the private address is discovered from
# Tailscale at install time and the join key is passed on the command line.
@{
    # Project
    Name               = 'Cogy Image'
    Role               = 'screenshot and image reader for the Cogy system'

    # Windows services and firewall rule group.
    # ServiceName runs the image service (image\image.py) on Port; it uses the
    # model server (OVMS), which listens on 127.0.0.1:OvmsPort only.
    ServiceName        = 'CogyImage'
    ServiceDisplayName = 'Cogy Image'
    OvmsServiceName    = 'CogyImageModel'
    OvmsDisplayName    = 'Cogy Image model server (OVMS)'
    OvmsPort           = 18812
    FirewallGroup      = 'Cogy Image'

    # Install location. Default: %ProgramData%\CogyImage
    InstallDirName     = 'CogyImage'

    # API
    Port               = 8812
    # Who may call the API: addresses or CIDR ranges. Cogy Code sends
    # screenshots to Cogy Server (POST /api/images/inspect), and Cogy Server
    # sends them here, so only Cogy Server is admitted. Set it to Cogy Server's
    # private address before installing, for example @('<cogy-server-address>').
    AllowFrom          = @()
    PrivateRange       = '100.64.0.0/10'   # address range of the private network

    # OpenVINO Model Server (Windows build without Python). The model needs
    # OpenVINO 2026.4.1 or later.
    OvmsVersion        = '2026.4.1'
    OvmsTag            = 'v2026.4.1'
    OvmsZip            = 'ovms_windows_2026.4.1_python_off.zip'
    OvmsSha256         = '1bc2372d81bb4767829a7bf513745bd481ccbfec9550e278804ebe2051e3b678'

    # Model: a vision-language model with its image encoder in the same folder.
    ModelId            = 'OpenVINO/Qwen3-VL-8B-Instruct-int4-ov'
    ContextLength      = 16384             # per request: prompt (with the image) plus output
    MaxTokens          = 1200              # per inspection
    RequestTimeout     = 300               # seconds the image service waits for the model server
    # The largest image the model sees, in pixels; larger ones are scaled
    # down by the model's processor. 1920 x 1080 is about 2,000 image tokens.
    MaxImagePixels     = 2073600
    MaxImageBytes      = 10485760          # 10 MB, as Cogy Code accepts

    # Python for the image service, image\*.py (embeddable build, standard library only)
    PythonVersion      = '3.12.10'
    PythonZipUrl       = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
    PythonSha256       = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'

    # WinSW runs image.py as a Windows service (start at boot, restart on a crash)
    WinSWUrl           = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
    WinSWSha256        = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'

    # Tailscale (installed by join-network.ps1 when missing)
    TailscaleMsiUrl    = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
}
