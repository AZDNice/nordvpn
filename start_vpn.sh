#!/bin/bash
[[ -n ${DEBUG} ]] && set -x
[[ -n ${COUNTRY} && -z ${CONNECT} ]] && CONNECT=${COUNTRY}
[[ "${GROUPID:-""}" =~ ^[0-9]+$ ]] && groupmod -g $GROUPID -o vpn

DOCKER_NET="$(ip -o addr show dev eth0 | awk '$3 == "inet" {print $4}')"

kill_switch() {
	local docker6_network="$(ip -o addr show dev eth0 | awk '$3 == "inet6" {print $4; exit}')"

	iptables -F
	iptables -X
	iptables -P INPUT DROP
	iptables -P FORWARD DROP
	iptables -P OUTPUT DROP
	iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -A INPUT -i lo -j ACCEPT
	iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -A FORWARD -i lo -j ACCEPT
	iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -A OUTPUT -o lo -j ACCEPT
	iptables -A OUTPUT -o tap+ -j ACCEPT
	iptables -A OUTPUT -o tun+ -j ACCEPT
	iptables -A OUTPUT -m owner --gid-owner vpn -j ACCEPT || {
		iptables -A OUTPUT -p udp -m udp --dport 53 -j ACCEPT
		iptables -A OUTPUT -p udp -m udp --dport 51820 -j ACCEPT
		iptables -A OUTPUT -p tcp -m tcp --dport 1194 -j ACCEPT
		iptables -A OUTPUT -p udp -m udp --dport 1194 -j ACCEPT
		iptables -A OUTPUT -p tcp -m tcp --dport 443 -j ACCEPT
		iptables -A OUTPUT -o eth0 -d api.nordvpn.com -j ACCEPT
	}
	iptables -t nat -A POSTROUTING -o tap+ -j MASQUERADE
	iptables -t nat -A POSTROUTING -o tun+ -j MASQUERADE
	if [[ -n ${DOCKER_NET} ]]; then
		iptables -A INPUT -s ${DOCKER_NET} -j ACCEPT
		iptables -A FORWARD -d ${DOCKER_NET} -j ACCEPT
		iptables -A FORWARD -s ${DOCKER_NET} -j ACCEPT
		iptables -A OUTPUT -d ${DOCKER_NET} -j ACCEPT
	fi
	[[ -n ${NETWORK} ]] && for net in ${NETWORK//[;,]/ }; do return_route ${net}; done
	[[ -n ${WHITELIST} ]] && for domain in ${WHITELIST//[;,]/ }; do white_list ${domain}; done

	ip6tables -F 2>/dev/null
	ip6tables -X 2>/dev/null
	ip6tables -P INPUT DROP 2>/dev/null
	ip6tables -P FORWARD DROP 2>/dev/null
	ip6tables -P OUTPUT DROP 2>/dev/null
	ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
	ip6tables -A INPUT -p icmp -j ACCEPT 2>/dev/null
	ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null
	ip6tables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
	ip6tables -A FORWARD -p icmp -j ACCEPT 2>/dev/null
	ip6tables -A FORWARD -i lo -j ACCEPT 2>/dev/null
	ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
	ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
	ip6tables -A OUTPUT -o tap+ -j ACCEPT 2>/dev/null
	ip6tables -A OUTPUT -o tun+ -j ACCEPT 2>/dev/null
	ip6tables -A OUTPUT -m owner --gid-owner vpn -j ACCEPT 2>/dev/null || {
		ip6tables -A OUTPUT -p udp -m udp --dport 53 -j ACCEPT 2>/dev/null
		ip6tables -A OUTPUT -p udp -m udp --dport 51820 -j ACCEPT 2>/dev/null
		ip6tables -A OUTPUT -p tcp -m tcp --dport 1194 -j ACCEPT 2>/dev/null
		ip6tables -A OUTPUT -p udp -m udp --dport 1194 -j ACCEPT 2>/dev/null
		ip6tables -A OUTPUT -p tcp -m tcp --dport 443 -j ACCEPT 2>/dev/null
		ip6tables -A OUTPUT -o eth0 -d api.nordvpn.com -j ACCEPT 2>/dev/null
	}
	ip6tables -t nat -A POSTROUTING -o tap+ -j MASQUERADE
	ip6tables -t nat -A POSTROUTING -o tun+ -j MASQUERADE
	if [[ -n ${docker6_network} ]]; then
		ip6tables -A INPUT -s ${docker6_network} -j ACCEPT 2>/dev/null
		ip6tables -A FORWARD -d ${docker6_network} -j ACCEPT 2>/dev/null
		ip6tables -A FORWARD -s ${docker6_network} -j ACCEPT 2>/dev/null
		ip6tables -A OUTPUT -d ${docker6_network} -j ACCEPT 2>/dev/null
	fi
	[[ -n ${NETWORK6} ]] && for net in ${NETWORK6//[;,]/ }; do return_route6 ${net}; done
}

global_return_routes() {
	local if=$(ip r | awk '/^default/ {print $5; quit}')
	local gw6="$(ip -6 r show dev $if | awk '/default/ {print $3}')" \
	gw="$(ip -4 r show dev $if | awk '/default/ {print $3}')" \
	ip6=$(ip -6 a show dev $if | awk -F '[ \t/]+' '/inet6.*global/ {print $3}') \
	ip=$(ip -4 a show dev $if | awk -F '[ \t/]+' '/inet .*global/ {print $3}')

	for i in $ip6; do
		ip -6 rule | grep -q "$i\\>" || ip -6 rule add from $i lookup 10
		ip6tables -S 2>/dev/null | grep -q "$i\\>" ||
			ip6tables -A INPUT -d $i -j ACCEPT 2>/dev/null
	done
	for g in $gw6; do
		ip -6 route | grep -q "$i\\>" || ip -6 route add default via $g table 10
	done

	for i in $ip; do
		ip -4 rule | grep -q "$i\\>" || ip rule add from $i lookup 10
		iptables -S | grep -q "$i\\>" || iptables -A INPUT -d $i -j ACCEPT
	done
	for g in $gw; do
		ip -4 route | grep -q "$i\\>" || ip route add default via $g table 10
	done
}

return_route() { # Add a route back to your network, so that return traffic works
	local network="$1" gw="$(ip route | awk '/default/ {print $3}')"
	ip route | grep -q "$network" || ip route add to $network via $gw dev eth0
	iptables -A INPUT -s $network -j ACCEPT
	iptables -A FORWARD -d $network -j ACCEPT
	iptables -A FORWARD -s $network -j ACCEPT
	iptables -A OUTPUT -d $network -j ACCEPT
}

return_route6() { # Add a route back to your network, so that return traffic works
	local network="$1" gw="$(ip -6 route | awk '/default/{print $3}')"
	ip -6 route | grep -q "$network" || ip -6 route add to $network via $gw dev eth0
	ip6tables -A INPUT -s $network -j ACCEPT 2>/dev/null
	ip6tables -A FORWARD -d $network -j ACCEPT 2>/dev/null
	ip6tables -A FORWARD -s $network -j ACCEPT 2>/dev/null
	ip6tables -A OUTPUT -d $network -j ACCEPT 2>/dev/null
}

white_list() { # Allow unsecured traffic for an specific domain
	local domain=$(echo $1 | sed 's/^.*:\/\///;s/\/.*$//')
	sg vpn -c "iptables  -A OUTPUT -o eth0 -d ${domain} -j ACCEPT"
	sg vpn -c "ip6tables -A OUTPUT -o eth0 -d ${domain} -j ACCEPT 2>/dev/null"
}

create_tun_device() {
	mkdir -p /dev/net
	[[ -c /dev/net/tun ]] || mknod -m 0666 /dev/net/tun c 10 200
}

setup_nordvpn() {
	[[ -n ${TECHNOLOGY} ]] && nordvpn set technology ${TECHNOLOGY}
	[[ -n ${PROTOCOL} ]] && nordvpn set protocol ${PROTOCOL}
	[[ -n ${OBFUSCATE} ]] && nordvpn set obfuscate ${OBFUSCATE}
	[[ -n ${CYBER_SEC} ]] && nordvpn set cybersec ${CYBER_SEC}
	[[ -n ${DNS} ]] && nordvpn set dns ${DNS//[;,]/ }
	[[ -n ${DOCKER_NET} ]] && nordvpn whitelist add subnet ${DOCKER_NET}
	[[ -n ${NETWORK} ]] && for net in ${NETWORK//[;,]/ }; do nordvpn whitelist add subnet ${net}; done
	[[ -n ${PORTS} ]] && for port in ${PORTS//[;,]/ }; do nordvpn whitelist add port ${port}; done
	[[ -n ${DEBUG} ]] && nordvpn -version && nordvpn settings
}

kill_switch
global_return_routes

pkill nordvpnd
rm -f /run/nordvpnd.sock
sg vpn -c nordvpnd &
sleep 0.5

nordvpn login -u ${USER} -p ${PASS}

setup_nordvpn
create_tun_device

nordvpn connect ${CONNECT} || exit 1
nordvpn status

tail -f --pid=$(pidof nordvpnd) /var/log/nordvpn/daemon.log
