////////////////////////////////////////////////////////////////////////////
//
// Copyright 2016 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

import Foundation
import RealmSwift

// Private Helpers

private var realm: Realm! // FIXME: shouldn't have to hold on to the Realm here. https://github.com/realm/realm-sync/issues/694
private var deduplicationNotificationToken: NotificationToken! // FIXME: Remove once core supports ordered sets: https://github.com/realm/realm-core/issues/1206

private func setDefaultRealmConfigurationWithUser(user: User) {
    Realm.Configuration.defaultConfiguration = Realm.Configuration(
        syncConfiguration: (user, Constants.syncServerURL!),
        objectTypes: [TaskListList.self, TaskList.self, Task.self]
    )
    realm = try! Realm()

    if realm.isEmpty {
        try! realm.write {
            let list = TaskList()
            list.id = Constants.defaultListID
            list.text = Constants.defaultListName
            let listLists = TaskListList()
            listLists.items.append(list)
            realm.add(listLists)
        }
    }

    // FIXME: Remove once core supports ordered sets: https://github.com/realm/realm-core/issues/1206
    deduplicationNotificationToken = realm.addNotificationBlock { _, realm in
        guard realm.objects(TaskListList.self).first!.items.count > 1 else {
            return
        }
        // Deduplicate
        dispatch_async(dispatch_queue_create("io.realm.RealmTasks.bg", nil)) {
            let items = try! Realm().objects(TaskListList.self).first!.items
            guard items.count > 1 else { return }

            try! items.realm!.write {
                let listReferenceIDs = NSCountedSet(array: items.map { $0.id })
                for id in listReferenceIDs where listReferenceIDs.countForObject(id) > 1 {
                    let id = id as! String
                    let indexesToRemove = items.enumerate().flatMap { index, element in
                        return element.id == id ? index : nil
                    }
                    indexesToRemove.dropFirst().reverse().forEach(items.removeAtIndex)
                }
            }
        }
    }
}

// Internal Functions

// returns true on success
func configureDefaultRealm() -> Bool {
    if let user = User.all().first {
        setDefaultRealmConfigurationWithUser(user)
        return true
    }
    return false
}

func authenticate(username username: String, password: String, register: Bool, callback: (NSError?) -> ()) {
    User.authenticateWithCredential(.usernamePassword(username, password: password, actions: register ? [.CreateAccount] : []),
                                    authServerURL: Constants.syncAuthURL) { user, error in
        if let user = user {
            setDefaultRealmConfigurationWithUser(user)
        }

        if let error = error where error.code == SyncError.HTTPStatusCodeError.rawValue && (error.userInfo["statusCode"] as? Int) == 400 {
            // FIXME: workararound for https://github.com/realm/realm-cocoa-private/issues/204
            // Note: "account not found" and "wrong password" have the same error code, so will show general error message for now
            callback(NSError(error: error, description: "Incorrect username or password.", recoverySuggestion: "Please check username and password or register a new account."))
        } else {
            callback(error)
        }
    }
}

private extension NSError {

    convenience init(error: NSError, description: String?, recoverySuggestion: String?) {
        var userInfo = error.userInfo

        userInfo[NSLocalizedDescriptionKey] = description
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = recoverySuggestion

        self.init(domain: error.domain, code: error.code, userInfo: userInfo)
    }

}
