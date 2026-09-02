use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::net::UdpSocket;

const SERVICE_TYPE: &str = "_igallery._tcp.local.";

/// M7: 由 caller 持有 daemon（存 AppState），进程退出前 unregister
pub fn register(mdns: &ServiceDaemon, port: u16, device_name: &str) {
    let hostname = gethostname::gethostname()
        .to_string_lossy()
        .to_string();
    let instance_name = format!("iGallery-{hostname}");

    let properties = [("version", "1"), ("name", device_name)];

    let local_ip = local_ipv4().unwrap_or_else(|| "0.0.0.0".to_string());

    let service = match ServiceInfo::new(
        SERVICE_TYPE,
        &instance_name,
        &format!("{hostname}.local."),
        &local_ip,
        port,
        &properties[..],
    ) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("mDNS ServiceInfo failed: {e}");
            return;
        }
    };

    if let Err(e) = mdns.register(service) {
        tracing::warn!("mDNS register failed: {e}");
        return;
    }

    tracing::info!("mDNS registered: {instance_name} at {local_ip}:{port}");
}

fn local_ipv4() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    Some(addr.ip().to_string())
}
