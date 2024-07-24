<?php

/**
 * Copyright (C) 2013-2024 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

class OMVModuleRestic extends \OMV\Engine\Module\ServiceAbstract implements \OMV\Engine\Notify\IListener
{
    public function getName()
    {
        return "Restic";
    }

    public function bindListeners(\OMV\Engine\Notify\Dispatcher $dispatcher)
    {
        // These will let OpenMediaVault know when we should prompt the user to apply the changes
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_MODIFY | OMV_NOTIFY_DELETE,
            "org.openmediavault.conf.service.restic.settings",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_MODIFY | OMV_NOTIFY_DELETE,
            "org.openmediavault.conf.service.restic.repo",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_MODIFY | OMV_NOTIFY_DELETE,
            "org.openmediavault.conf.service.restic.snapshot",
            [ $this, "setDirty" ]
        );
        $dispatcher->addListener(
            OMV_NOTIFY_CREATE | OMV_NOTIFY_MODIFY | OMV_NOTIFY_DELETE,
            "org.openmediavault.conf.service.restic.envvar",
            [ $this, "setDirty" ]
        );
    }
}
