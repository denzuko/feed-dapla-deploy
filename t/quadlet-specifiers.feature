Feature: feed-dapla-deploy rootless Podman quadlet deploy
  As a dapla.net operator
  I want every exported function and property verified
  So regressions are caught before reaching the host

  Background:
    Given the deploy system is loaded

  Scenario: Network unit uses netavark bridge
    When gotosocial-network-sections is called
    Then the INI contains "Driver=bridge"
    And the INI does not contain "Internal=true"

  Scenario: Network unit has correct VLSM allocation
    When gotosocial-network-sections is called
    Then the INI contains "Subnet=10.89.2.20/30"
    And the INI contains "Gateway=10.89.2.21"

  Scenario: Container home profile is read-only via %%h
    When gotosocial-container-sections is called
    Then a Volume line starts with "%%h:"
    And that Volume line ends with ":ro"

  Scenario: Writable data uses /srv/%%U specifier
    When gotosocial-container-sections is called
    Then a Volume line starts with "/srv/%%U"
    And no Volume line contains the bare host path

  Scenario: HAProxy backend targets netavark gateway
    When haproxy-vhost-config is called
    Then the output contains "10.89.2.21:8080"
    And the output does not contain "127.0.0.1"

  Scenario: All defprops and functions are exported
    Then haproxy-vhost-written is fbound
    And quadlets-written is fbound
    And decommissioned is fbound
    And deploy-app is fbound
