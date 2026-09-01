use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::net::UdpSocket;

const SERVICE_TYPE: &str = "_igallery._tcp.local.";

pub fn register(port: u16, device_name: &str) {
    let mdns = ServiceDaemon::new().expect("failed to create mDNS daemon");

    let hostname = gethostname::gethostname()
        .to_string_lossy()
        .to_string();
    let instance_name = format!("iGallery-{hostname}");

    let properties = [("version", "1"), ("name", device_name)];

    let local_ip = local_ipv4().unwrap_or_else(|| "0.0.0.0".to_string());

    let service = ServiceInfo::new(
        SERVICE_TYPE,
        &instance_name,
        &format!("{hostname}.local."),
        &local_ip,
        port,
        &properties[..],
    )
    .expect("failed to create service info");

    mdns.register(service)
        .expect("failed to register mDNS service");

    tracing::info!("mDNS registered: {instance_name} at {local_ip}:{port}");

    std::mem::forget(mdns);
}

fn local_ipv4() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    Some(addr.ip().to_string())
}
