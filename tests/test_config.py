import ipaddress

def test_client_address_example():
    x = ipaddress.ip_interface("10.77.0.2/32")
    assert x.version == 4
    assert x.network.prefixlen == 32

def test_reject_overlapping_tunnel_example():
    a = ipaddress.ip_network("10.88.0.0/30")
    b = ipaddress.ip_network("10.88.0.0/30")
    assert a.overlaps(b)
