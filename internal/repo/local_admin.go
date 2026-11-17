package repo

import (
	"errors"
	"time"

	"agentflow/internal/domain"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

// BootstrapLocalAdmin 显式创建初始管理员，重复执行时保留已有密码。
func (r *UsersRepo) BootstrapLocalAdmin(password string) (domain.User, error) {
	if len(password) < MinPasswordLength || len(password) > MaxPasswordLength {
		return domain.User{}, errPasswordLength
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return domain.User{}, err
	}
	var result domain.User
	err = r.DB.Transaction(func(tx *gorm.DB) error {
		users := *r
		users.deps = &deps{DB: tx}
		var existing userRow
		err := users.locking(tx).Where("LOWER(login_name) = ?", "admin").First(&existing).Error
		if err == nil {
			var account localAccountRow
			if err := tx.Where("user_id = ?", existing.ID).First(&account).Error; err != nil {
				if errors.Is(err, gorm.ErrRecordNotFound) {
					return ErrLoginTaken
				}
				return err
			}
			if existing.PlatformRole != domain.PlatformRoleAdmin {
				return ErrLoginTaken
			}
			var ok bool
			result, ok = users.User(existing.ID)
			if !ok {
				return errors.New("could not read administrator")
			}
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		now := time.Now().UTC()
		row := userRow{LoginName: "admin", ChineseName: "admin", PlatformRole: domain.PlatformRoleAdmin, Created: &now, Updated: &now}
		if err := tx.Create(&row).Error; err != nil {
			return err
		}
		if err := tx.Create(&localAccountRow{UserID: row.ID, PasswordHash: string(hash)}).Error; err != nil {
			return err
		}
		var ok bool
		result, ok = users.User(row.ID)
		if !ok {
			return errors.New("could not read administrator")
		}
		return nil
	})
	return result, err
}
