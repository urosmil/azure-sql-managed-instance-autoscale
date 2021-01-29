# Schedule Azure SQL Managed Instance scaling using Tags

## What it does

This runbook executes script that performs SQL Managed Instance scaling based on the configuration set through Azure Tags. This can be applied on the entire environment (Resource group) or on individual managed instance. For example, you could tag a single managed instance or group of managed instances to automatically scale down and run on lower configuration between 10:00 PM and 6:00 AM, all day on Saturdays and Sundays, and during specific days of the year, like December 25.

## Why use this

Frequent scenario for the customers running Azure SQL Managed Instance is scenario where instance needs higher compute or storage during period of the day, while rest of the time it is possible to run the lower layer. Reason for this can either some ETL job that is running couple of hours, or peak hours during the weekends. In order to reduce the costs, customers perform scaling to the lower compute (which is the main price driver in Azure SQL Managed Instance) during quiet hours and then increasing compute power during busy hours.

## Usage patterns

<ul>
  <li>Running ETL jobs during the night</li>
  <li>Perform intensive tests during the working hours</li>
  <li>Increased usage during the weekends</li>
  <li>Increased usage during the working days</li>
</ul>

<b>It is recommended to use the script only for General Purpose instances as this service tier supports online storage scaling.</b> For more details visit [Overview of Azure SQL Managed Instance management operations](https://docs.microsoft.com/azure/azure-sql/managed-instance/management-operations-overview)

## How to configure

There are 5 tags that need to be populated in order for runbook to identify scaling instances:

<ul>
  <li>AutoScalingSchedule - <b>Must be set on the resource group</b></li>
  <li>AutoScalingLowerCores</li>
  <li>AutoScalingLowerStorage</li>
  <li>AutoScalingUpperCores</li>
  <li>AutoScalingUpperStorage</li>
</ul>

If any of the values is configured at the instance level it will override default value configured at the resource group level.

### How to set values for each parameter

<b>AutoScalingSchedule</b>

| Description | Tag Value |
| --- | --- |
|Scale down at 10PM and scale up at 6 AM UTC every day|10pm -> 6am|
|Scale down at 10PM and scale up at 6 AM UTC every day (different format, same result as above)|22:00 -> 06:00|
|Scale down all day Saturday and Sunday (midnight to midnight)|Saturday, Sunday|
|Scale down at 2AM and scale up at 7AM UTC every day and run scaled down instance all day on weekends|2:00 -> 7:00, Saturday, Sunday|
|Scale down on Christmas Day and New Year’s Day|December 25, January 1|
|Scale down at 2AM and scale up at 7AM UTC every day, and run scaled down instance all day on weekends, and on Christmas Day|2:00 -> 7:00, Saturday, Sunday, December 25|

<b>AutoScalingLowerCores / AutoScalingUpperCores</b>

Available vCores values are: 4, 8, 16, 24, 32, 40, 64, 80. However, these values depend on hardware generation and service tier managed instance is running on. For more details visit [Azure SQL Managed Instance resource limits](https://docs.microsoft.com/azure/azure-sql/managed-instance/resource-limits).

<b>AutoScalingLowerStorage / AutoScalingUpperStorage</b>
Value is provided in GBs with increment of 32 (for example: 1024). For resource limits visit [Azure SQL Managed Instance resource limits](https://docs.microsoft.com/azure/azure-sql/managed-instance/resource-limits).

## Credits
[Automys scheduled Virtual Machine Shutdown/Startup](https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure)
