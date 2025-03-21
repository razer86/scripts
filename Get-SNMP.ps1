$SNMP = New-Object -ComObject olePrn.OleSNMP

If ($SNMP.open(172.16.60.254, "Public", 10, 3000))

{

$Message = "Open"

}

Else

{

$Message = "Closed"

}